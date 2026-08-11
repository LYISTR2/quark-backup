#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="quark-backup"
REAL_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)}"
REAL_HOME="${REAL_HOME:-$HOME}"
DEFAULT_DATA_DIR="${QUARK_BACKUP_HOME:-$REAL_HOME/.local/share/quark-backup}"
DEFAULT_SKILL_DIR="$DEFAULT_DATA_DIR/vendor/quarkclouddrive"
SKILL_DIR="${QUARK_SKILL_DIR:-$DEFAULT_SKILL_DIR}"
RUNTIME_DIR="${QUARK_RUNTIME_DIR:-$DEFAULT_DATA_DIR/runtime}"
CLI="$SKILL_DIR/scripts/quark-drive.cjs"
INSTALLER="$SKILL_DIR/scripts/install.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/$APP_NAME.lock"
SESSION_INPUT="夸克网盘一键交互式备份"
SESSION_ID=""

if [[ -t 1 ]]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'; C_BLUE='\033[34m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'
else
  C_RESET=''; C_BOLD=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

info() { printf '%b[信息]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[注意]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
夸克网盘一键交互式备份工具

用法：
  quark-backup.sh                 打开交互菜单
  quark-backup.sh setup           交互设置备份来源、网盘目录和定时计划
  quark-backup.sh setup --source /path [--source /path2] --remote-dir 服务器备份 --mode direct
  quark-backup.sh login [授权码]  登录/重新授权（无授权码时显示授权入口）
  quark-backup.sh status          查看账号、配置和定时任务状态
  quark-backup.sh run             立即备份（默认原文件直传，不压缩）
  quark-backup.sh schedule        安装/更新定时任务
  quark-backup.sh disable         关闭定时任务
  quark-backup.sh help            显示帮助

环境变量：
  QUARK_SKILL_DIR                 自定义夸克 Skill 目录
  QUARK_BACKUP_KEEP_LOCAL         压缩模式下保留本地压缩包（1/0）
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

ensure_environment() {
  require_command bash
  require_command node
  require_command python3
  require_command tar
  require_command flock
  [[ -f "$CLI" ]] || die "未找到夸克网盘 Skill：$CLI"
  [[ -f "$INSTALLER" ]] || die "Skill 安装检查脚本不存在：$INSTALLER"
  if ! bash "$INSTALLER" >/dev/null; then
    warn "夸克网盘 Skill 更新检查失败，继续使用已安装的 CLI"
  fi
}

new_session_id() {
  SESSION_ID=$(python3 - <<'PY'
import secrets, string, time
alphabet = string.ascii_lowercase + string.digits
print(f"{int(time.time())}-{''.join(secrets.choice(alphabet) for _ in range(6))}")
PY
)
}

run_cli() {
  [[ -n "$SESSION_ID" ]] || new_session_id
  install -d -m 0700 "$RUNTIME_DIR"
  (
    cd "$RUNTIME_DIR"
    HERMES_SESSION_ID="${HERMES_SESSION_ID:-quark-backup-standalone}" \
      node "$CLI" "$@" --session-input "$SESSION_INPUT" --session-id "$SESSION_ID"
  )
}

load_config() {
  SOURCE_PATHS=()
  REMOTE_DIR="Hermes备份"
  SCHEDULE="daily"
  SCHEDULE_TIME="03:30"
  WEEKDAY="0"
  BACKUP_MODE="direct"
  KEEP_LOCAL="0"
  LOCAL_DIR="/var/backups/quark-backup"
  ARCHIVE_PREFIX="server-backup"
  if [[ -f "$CONFIG_FILE" ]]; then
    local -a values=()
    mapfile -d '' -t values < <(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
p=sys.argv[1]
try:
    d=json.load(open(p, encoding='utf-8'))
except Exception as e:
    raise SystemExit(f"配置读取失败: {e}")
version = int(d.get('version', 1) or 1)
mode_default = 'archive' if version < 2 else 'direct'
vals = [
    d.get('remote_dir', 'Hermes备份'),
    d.get('schedule', 'daily'),
    d.get('schedule_time', '03:30'),
    d.get('weekday', '0'),
    d.get('backup_mode', mode_default),
    d.get('keep_local', '0'),
    d.get('local_dir', '/var/backups/quark-backup'),
    d.get('archive_prefix', 'server-backup'),
]
for value in vals:
    sys.stdout.write(str(value) + '\0')
for path in d.get('source_paths', []):
    sys.stdout.write(str(path) + '\0')
PY
)
    ((${#values[@]} >= 8)) || die "配置内容不完整：$CONFIG_FILE"
    REMOTE_DIR=${values[0]}
    SCHEDULE=${values[1]}
    SCHEDULE_TIME=${values[2]}
    WEEKDAY=${values[3]}
    BACKUP_MODE=${values[4]}
    KEEP_LOCAL=${values[5]}
    LOCAL_DIR=${values[6]}
    ARCHIVE_PREFIX=${values[7]}
    SOURCE_PATHS=()
    ((${#values[@]} == 8)) || SOURCE_PATHS=("${values[@]:8}")
  fi
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  python3 - "$CONFIG_FILE" "$REMOTE_DIR" "$SCHEDULE" "$SCHEDULE_TIME" "$WEEKDAY" "$BACKUP_MODE" "$KEEP_LOCAL" "$LOCAL_DIR" "$ARCHIVE_PREFIX" "${SOURCE_PATHS[@]}" <<'PY'
import json, os, sys, tempfile
out, remote, schedule, at, weekday, mode, keep, local_dir, prefix, *sources = sys.argv[1:]
data = {
    'version': 2,
    'source_paths': sources,
    'remote_dir': remote,
    'schedule': schedule,
    'schedule_time': at,
    'weekday': weekday,
    'backup_mode': mode,
    'keep_local': keep,
    'local_dir': local_dir,
    'archive_prefix': prefix,
}
os.makedirs(os.path.dirname(out), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=os.path.dirname(out), text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  chmod 600 "$CONFIG_FILE"
}

json_result_code() {
  python3 -c 'import json,sys
last=None
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except Exception:
        continue
    if obj.get("type")=="result": last=obj
print("" if last is None else last.get("code",""))'
}

json_result_message() {
  python3 -c 'import json,sys
last=None
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except Exception:
        continue
    if obj.get("type")=="result": last=obj
print("未返回有效结果" if last is None else last.get("msg", ""))'
}

json_data_field() {
  local field="$1"
  python3 -c 'import json,sys
field=sys.argv[1]; last=None
for line in sys.stdin:
    try:
        obj=json.loads(line)
    except Exception:
        continue
    if obj.get("type")=="result": last=obj
v=(last or {}).get("data",{}).get(field,"")
if isinstance(v,(dict,list)): print(json.dumps(v,ensure_ascii=False))
else: print(v)' "$field"
}

show_user_info() {
  local out code
  set +e
  out=$(run_cli get-user-info 2>&1)
  local rc=$?
  set -e
  code=$(printf '%s\n' "$out" | json_result_code)
  if [[ $rc -ne 0 || "$code" != "0" ]]; then
    printf '%s\n' "$out" | json_result_message
    return 1
  fi
  printf '%s\n' "$out" | python3 -c 'import json,sys
last={}
for line in sys.stdin:
    try:
        o=json.loads(line)
    except Exception:
        continue
    if o.get("type")=="result": last=o
u=last.get("data",{}).get("userInfo",{})
v=last.get("data",{}).get("vipInfo",{})
used=int(v.get("used") or 0); cap=int(v.get("capacity") or 0)
def fmt(n):
    units=["B","KB","MB","GB","TB","PB"]
    x=float(n)
    for unit in units:
        if x<1024 or unit==units[-1]: return f"{x:.2f} {unit}"
        x/=1024
nickname_key="nickname"
vip_type_key="vipType"
print("账号：{}".format(u.get(nickname_key, "未知")))
print("会员：{}".format(v.get(vip_type_key, "未知")))
if cap: print("空间：{} / {}".format(fmt(used), fmt(cap)))'
}

login() {
  ensure_environment
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    info "正在生成授权入口……"
    local out
    set +e
    out=$(run_cli login 2>&1)
    local rc=$?
    set -e
    printf '%s\n' "$out" | python3 -c 'import json,re,sys
text=sys.stdin.read(); msg=""
for line in text.splitlines():
    try:
        o=json.loads(line)
        if o.get("type")=="result": msg=o.get("msg","")
    except Exception: pass
m=re.search(r"https://pan\.quark\.cn/[^\s]+", msg or text)
if m:
    print("请打开下面的地址，在夸克中确认授权：")
    print(m.group(0))
    print("完成后，把页面显示的授权码粘贴回本工具。")
else:
    print(msg or text)'
    if [[ -t 0 ]]; then
      printf '授权码（直接回车取消）：'
      IFS= read -r token
    else
      return "$rc"
    fi
  fi
  [[ -n "$token" ]] || { warn "已取消登录"; return 1; }
  local out code
  set +e
  out=$(run_cli login --token "$token" 2>&1)
  local rc=$?
  set -e
  code=$(printf '%s\n' "$out" | json_result_code)
  if [[ $rc -eq 0 && "$code" == "0" ]]; then
    local auth_config="$RUNTIME_DIR/hermes/config.json"
    [[ -f "$auth_config" ]] && chmod 600 "$auth_config"
    ok "夸克网盘授权成功"
    show_user_info || true
    return 0
  fi
  printf '%s\n' "$out" | json_result_message >&2
  return 1
}

validate_sources() {
  ((${#SOURCE_PATHS[@]} > 0)) || die "尚未设置备份来源，请先运行 setup"
  local p
  for p in "${SOURCE_PATHS[@]}"; do
    [[ -e "$p" ]] || die "备份来源不存在：$p"
    case "$p" in
      /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) die "不支持备份虚拟系统目录：$p" ;;
    esac
    if [[ "$BACKUP_MODE" == "archive" && ( "$LOCAL_DIR" == "$p" || "$LOCAL_DIR" == "$p"/* ) ]]; then
      die "本地压缩包目录不能位于备份来源内部，否则会递归打包：$LOCAL_DIR"
    fi
  done
}

create_remote_folder() {
  local out code fid msg
  set +e
  out=$(run_cli create-folder --dir-path "$REMOTE_DIR" --parent-fid 0 2>&1)
  local rc=$?
  set -e
  code=$(printf '%s\n' "$out" | json_result_code)
  if [[ $rc -ne 0 || "$code" != "0" ]]; then
    msg=$(printf '%s\n' "$out" | json_result_message)
    die "创建/查找网盘备份目录失败：$msg"
  fi
  fid=$(printf '%s\n' "$out" | json_data_field fid)
  [[ -n "$fid" ]] || die "网盘未返回备份目录标识"
  printf '%s' "$fid"
}

create_remote_snapshot_folder() {
  local parent_fid="$1" stamp host name out code fid msg
  stamp=$(date '+%Y%m%d-%H%M%S')
  host=$(hostname -s 2>/dev/null || printf 'host')
  name="${ARCHIVE_PREFIX}-${host}-${stamp}"
  set +e
  out=$(run_cli create-folder --dir-path "$name" --parent-fid "$parent_fid" 2>&1)
  local rc=$?
  set -e
  code=$(printf '%s\n' "$out" | json_result_code)
  if [[ $rc -ne 0 || "$code" != "0" ]]; then
    msg=$(printf '%s\n' "$out" | json_result_message)
    die "创建本次备份目录失败：$msg"
  fi
  fid=$(printf '%s\n' "$out" | json_data_field fid)
  [[ -n "$fid" ]] || die "网盘未返回本次备份目录标识"
  printf '%s' "$fid"
}

make_archive() {
  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"
  local stamp host archive manifest
  stamp=$(date '+%Y%m%d-%H%M%S')
  host=$(hostname -s 2>/dev/null || printf 'host')
  archive="$LOCAL_DIR/${ARCHIVE_PREFIX}-${host}-${stamp}.tar.gz"
  manifest="$LOCAL_DIR/.${ARCHIVE_PREFIX}-${stamp}.files"
  printf '%s\0' "${SOURCE_PATHS[@]}" > "$manifest"
  info "正在创建备份压缩包……"
  set +e
  tar --absolute-names --warning=no-file-changed --ignore-failed-read -czf "$archive" --null --files-from "$manifest"
  local tar_rc=$?
  set -e
  rm -f "$manifest"
  if ((tar_rc > 1)); then
    rm -f "$archive"
    die "创建压缩包失败（tar 退出码：$tar_rc）"
  fi
  ((tar_rc == 1)) && warn "部分文件在备份过程中发生变化或无法读取，已上传其余可读取内容"
  chmod 600 "$archive"
  CREATED_ARCHIVE="$archive"
}

upload_paths() {
  local remote_fid="$1" failure_note="$2"
  shift 2
  local -a paths=("$@")
  local out code msg path
  if ((${#paths[@]} == 1)); then
    info "正在上传 $(basename "${paths[0]}")……"
  else
    info "正在上传 ${#paths[@]} 个备份来源……"
  fi
  set +e
  out=$(run_cli upload "${paths[@]}" --parent-fid "$remote_fid" 2>&1)
  local rc=$?
  set -e
  code=$(printf '%s\n' "$out" | json_result_code)
  if [[ $rc -ne 0 || "$code" != "0" ]]; then
    msg=$(printf '%s\n' "$out" | json_result_message)
    die "上传失败：$msg${failure_note:+（$failure_note）}"
  fi
  path=$(printf '%s\n' "$out" | json_data_field fullPath)
  if [[ -n "$path" ]]; then
    ok "备份已上传到 $path"
  else
    ok "备份已上传到夸克网盘"
  fi
}

run_backup() {
  ensure_environment
  load_config
  validate_sources
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有备份任务正在运行"
  show_user_info >/dev/null || die "夸克账号未授权或授权已过期，请先运行 login"
  local remote_fid archive keep backup_fid
  remote_fid=$(create_remote_folder)
  case "$BACKUP_MODE" in
    direct)
      backup_fid=$(create_remote_snapshot_folder "$remote_fid")
      upload_paths "$backup_fid" "原文件保留在本机" "${SOURCE_PATHS[@]}"
      ok "原文件已直接上传，未创建压缩包"
      ;;
    archive)
      make_archive
      archive=$CREATED_ARCHIVE
      upload_paths "$remote_fid" "本地压缩包已保留：$archive" "$archive"
      keep="${QUARK_BACKUP_KEEP_LOCAL:-$KEEP_LOCAL}"
      if [[ "$keep" == "1" ]]; then
        ok "本地副本已保留：$archive"
      else
        rm -f "$archive"
        ok "本地临时压缩包已清理"
      fi
      ;;
    *) die "不支持的备份模式：$BACKUP_MODE" ;;
  esac
}

validate_time() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

schedule_cron_line() {
  local minute hour
  minute=${SCHEDULE_TIME#*:}; hour=${SCHEDULE_TIME%:*}
  case "$SCHEDULE" in
    daily) printf '%s %s * * *' "$minute" "$hour" ;;
    weekly) [[ "$WEEKDAY" =~ ^[0-6]$ ]] || die "星期必须为 0-6（0=周日）"; printf '%s %s * * %s' "$minute" "$hour" "$WEEKDAY" ;;
    *) die "不支持的计划：$SCHEDULE" ;;
  esac
}

install_schedule() {
  ensure_environment
  load_config
  validate_sources
  validate_time "$SCHEDULE_TIME" || die "时间格式必须为 HH:MM"
  require_command crontab
  local cron_expr tmp current_file start end
  cron_expr=$(schedule_cron_line)
  start="# BEGIN QUARK-BACKUP"
  end="# END QUARK-BACKUP"
  tmp=$(mktemp)
  current_file=$(mktemp)
  crontab -l > "$current_file" 2>/dev/null || true
  python3 - "$start" "$end" "$cron_expr" "$0" "$current_file" > "$tmp" <<'PY'
import shlex, sys
start,end,expr,script,path=sys.argv[1:]
text=open(path, encoding='utf-8').read().splitlines()
out=[]; inside=False
for line in text:
    if line==start: inside=True; continue
    if line==end: inside=False; continue
    if not inside: out.append(line)
while out and not out[-1].strip(): out.pop()
if out: out.append('')
cmd=f"{expr} {shlex.quote(script)} run >>/var/log/quark-backup.log 2>&1"
out += [start, cmd, end]
print('\n'.join(out))
PY
  crontab "$tmp"
  rm -f "$tmp" "$current_file"
  ok "定时任务已安装：$cron_expr"
}

disable_schedule() {
  require_command crontab
  local current_file tmp start end
  start="# BEGIN QUARK-BACKUP"; end="# END QUARK-BACKUP"
  tmp=$(mktemp)
  current_file=$(mktemp)
  crontab -l > "$current_file" 2>/dev/null || true
  python3 - "$start" "$end" "$current_file" > "$tmp" <<'PY'
import sys
start,end,path=sys.argv[1:]
inside=False
for line in open(path, encoding='utf-8'):
    line=line.rstrip('\n')
    if line==start: inside=True; continue
    if line==end: inside=False; continue
    if not inside: print(line)
PY
  crontab "$tmp"
  rm -f "$tmp" "$current_file"
  ok "夸克备份定时任务已关闭"
}

show_status() {
  ensure_environment
  load_config
  printf '%b夸克网盘账号%b\n' "$C_BOLD" "$C_RESET"
  if ! show_user_info; then warn "当前未授权，可运行：$0 login"; fi
  printf '\n%b备份设置%b\n' "$C_BOLD" "$C_RESET"
  if ((${#SOURCE_PATHS[@]} == 0)); then
    printf '尚未配置\n'
  else
    printf '来源：\n'
    printf '  - %s\n' "${SOURCE_PATHS[@]}"
    printf '网盘目录：/%s\n' "$REMOTE_DIR"
    if [[ "$BACKUP_MODE" == "direct" ]]; then
      printf '上传方式：原文件直接上传（不压缩）\n'
    else
      printf '上传方式：压缩包上传\n'
      printf '本地目录：%s\n' "$LOCAL_DIR"
      printf '保留本地副本：%s\n' "$([[ "$KEEP_LOCAL" == "1" ]] && printf '是' || printf '否')"
    fi
    if [[ "$SCHEDULE" == "off" ]]; then
      printf '计划：关闭\n'
    else
      printf '计划：%s %s' "$SCHEDULE" "$SCHEDULE_TIME"
      [[ "$SCHEDULE" == "weekly" ]] && printf '（星期 %s）' "$WEEKDAY"
      printf '\n'
    fi
  fi
  printf '\n%b定时任务%b\n' "$C_BOLD" "$C_RESET"
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q '^# BEGIN QUARK-BACKUP$'; then
    crontab -l 2>/dev/null | sed -n '/^# BEGIN QUARK-BACKUP$/,/^# END QUARK-BACKUP$/p'
  else
    printf '未启用\n'
  fi
}

prompt_default() {
  local prompt="$1" default="$2" answer
  printf '%s [%s]：' "$prompt" "$default" >&2
  IFS= read -r answer
  printf '%s' "${answer:-$default}"
}

setup_interactive() {
  ensure_environment
  load_config
  [[ -t 0 ]] || die "setup 需要交互式终端"
  printf '%b夸克网盘备份设置%b\n\n' "$C_BOLD" "$C_RESET"
  local default_sources raw p
  if ((${#SOURCE_PATHS[@]})); then
    default_sources=$(IFS=,; printf '%s' "${SOURCE_PATHS[*]}")
  else
    default_sources="$REAL_HOME"
  fi
  raw=$(prompt_default "备份来源（多个路径用英文逗号分隔）" "$default_sources")
  IFS=',' read -r -a SOURCE_PATHS <<< "$raw"
  local cleaned=()
  for p in "${SOURCE_PATHS[@]}"; do
    p=$(printf '%s' "$p" | python3 -c 'import sys; print(sys.stdin.read().strip(), end="")')
    [[ -n "$p" ]] && cleaned+=("$p")
  done
  SOURCE_PATHS=("${cleaned[@]}")
  REMOTE_DIR=$(prompt_default "夸克网盘备份文件夹（创建在网盘顶层）" "$REMOTE_DIR")
  [[ "$REMOTE_DIR" != */* ]] || die "备份文件夹请输入单层名称，不要包含 /"
  BACKUP_MODE=$(prompt_default "上传方式（direct=原文件直传，archive=压缩包）" "$BACKUP_MODE")
  case "$BACKUP_MODE" in
    direct) ;;
    archive)
      LOCAL_DIR=$(prompt_default "本地临时压缩包目录" "$LOCAL_DIR")
      ARCHIVE_PREFIX=$(prompt_default "压缩包文件名前缀" "$ARCHIVE_PREFIX")
      local keep_answer
      keep_answer=$(prompt_default "上传后保留本地副本？(y/N)" "$([[ "$KEEP_LOCAL" == "1" ]] && printf 'y' || printf 'N')")
      [[ "$keep_answer" =~ ^[Yy]$ ]] && KEEP_LOCAL=1 || KEEP_LOCAL=0
      ;;
    *) die "上传方式只能是 direct 或 archive" ;;
  esac
  validate_sources
  local sched
  sched=$(prompt_default "定时频率（daily/weekly/off）" "$SCHEDULE")
  case "$sched" in
    daily|weekly) SCHEDULE="$sched" ;;
    off) SCHEDULE="off" ;;
    *) die "频率只能是 daily、weekly 或 off" ;;
  esac
  if [[ "$SCHEDULE" != "off" ]]; then
    SCHEDULE_TIME=$(prompt_default "执行时间（HH:MM）" "$SCHEDULE_TIME")
    validate_time "$SCHEDULE_TIME" || die "时间格式无效"
    if [[ "$SCHEDULE" == "weekly" ]]; then
      WEEKDAY=$(prompt_default "星期（0=周日，1=周一……6=周六）" "$WEEKDAY")
      [[ "$WEEKDAY" =~ ^[0-6]$ ]] || die "星期必须为 0-6"
    fi
  fi
  save_config
  ok "配置已保存"
  if [[ "$SCHEDULE" == "off" ]]; then
    disable_schedule
  else
    install_schedule
  fi
  show_status
}

set_config_noninteractive() {
  ensure_environment
  load_config
  local -a new_sources=()
  local install_cron=0
  while (($#)); do
    case "$1" in
      --source)
        (($# >= 2)) || die "--source 缺少路径"
        new_sources+=("$2"); shift 2 ;;
      --remote-dir)
        (($# >= 2)) || die "--remote-dir 缺少名称"
        REMOTE_DIR="$2"; shift 2 ;;
      --mode)
        (($# >= 2)) || die "--mode 缺少值"
        BACKUP_MODE="$2"; shift 2 ;;
      --local-dir)
        (($# >= 2)) || die "--local-dir 缺少路径"
        LOCAL_DIR="$2"; shift 2 ;;
      --prefix)
        (($# >= 2)) || die "--prefix 缺少值"
        ARCHIVE_PREFIX="$2"; shift 2 ;;
      --schedule)
        (($# >= 2)) || die "--schedule 缺少值"
        SCHEDULE="$2"; shift 2 ;;
      --time)
        (($# >= 2)) || die "--time 缺少值"
        SCHEDULE_TIME="$2"; shift 2 ;;
      --weekday)
        (($# >= 2)) || die "--weekday 缺少值"
        WEEKDAY="$2"; shift 2 ;;
      --keep-local)
        (($# >= 2)) || die "--keep-local 缺少值"
        KEEP_LOCAL="$2"; shift 2 ;;
      --install-cron) install_cron=1; shift ;;
      *) die "未知 setup 选项：$1" ;;
    esac
  done
  ((${#new_sources[@]} == 0)) || SOURCE_PATHS=("${new_sources[@]}")
  [[ "$REMOTE_DIR" != */* ]] || die "备份文件夹请输入单层名称，不要包含 /"
  [[ "$BACKUP_MODE" == "direct" || "$BACKUP_MODE" == "archive" ]] || die "--mode 只能是 direct 或 archive"
  [[ "$KEEP_LOCAL" == "0" || "$KEEP_LOCAL" == "1" ]] || die "--keep-local 只能是 0 或 1"
  validate_sources
  case "$SCHEDULE" in
    daily|weekly) validate_time "$SCHEDULE_TIME" || die "时间格式必须为 HH:MM" ;;
    off) ;;
    *) die "--schedule 只能是 daily、weekly 或 off" ;;
  esac
  [[ "$SCHEDULE" != "weekly" || "$WEEKDAY" =~ ^[0-6]$ ]] || die "--weekday 必须为 0-6"
  save_config
  ok "配置已保存"
  if ((install_cron)); then
    if [[ "$SCHEDULE" == "off" ]]; then disable_schedule; else install_schedule; fi
  fi
}

interactive_menu() {
  [[ -t 0 ]] || { usage; exit 1; }
  while true; do
    printf '\n%b夸克网盘一键备份%b\n' "$C_BOLD" "$C_RESET"
    printf '1) 登录 / 重新授权\n2) 设置备份与定时计划\n3) 立即备份\n4) 查看状态\n5) 关闭定时任务\n0) 退出\n'
    printf '请选择：'
    local choice
    IFS= read -r choice
    case "$choice" in
      1) login || true ;;
      2) setup_interactive ;;
      3) run_backup ;;
      4) show_status ;;
      5) disable_schedule ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu) interactive_menu ;;
    setup)
      shift
      if (($#)); then set_config_noninteractive "$@"; else setup_interactive; fi
      ;;
    login) shift; login "${1:-}" ;;
    status) show_status ;;
    run|backup) run_backup ;;
    schedule) install_schedule ;;
    disable) disable_schedule ;;
    help|-h|--help) usage ;;
    *) usage; die "未知命令：$cmd" ;;
  esac
}

main "$@"
