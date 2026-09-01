#!/usr/bin/env bats

setup() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/root"
  export HOME="$TEST_ROOT/home"
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export XDG_RUNTIME_DIR="$TEST_ROOT/run"
  export QUARK_SKILL_DIR="$TEST_ROOT/vendor/quarkclouddrive"
  export QUARK_RUNTIME_DIR="$TEST_ROOT/runtime"
  export APP="/opt/quark-backup/quark-backup.sh"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$QUARK_SKILL_DIR/scripts" "$TEST_ROOT/bin" "$TEST_ROOT/source"
  printf 'fixture\n' > "$TEST_ROOT/source/file.txt"
  cat > "$QUARK_SKILL_DIR/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$QUARK_SKILL_DIR/scripts/install.sh"
  : > "$QUARK_SKILL_DIR/scripts/quark-drive.cjs"
  export NODE_CALLS="$TEST_ROOT/node-calls.log"
  cat > "$TEST_ROOT/bin/node" <<'SH'
#!/usr/bin/env bash
cmd="${2:-}"
printf '%q ' "$@" >> "${NODE_CALLS:?}"
printf '\n' >> "$NODE_CALLS"
case "$cmd" in
  get-user-info)
    printf '%s\n' '{"code":0,"msg":"成功","data":{"vipInfo":{"vipType":"SVIP","used":1024,"capacity":2048},"userInfo":{"nickname":"测试账号"}},"action":"get-user-info","type":"result"}'
    ;;
  create-folder)
    if printf '%s\n' "$@" | grep -Eq -- '(server-backup|nightly backup)-'; then
      printf '%s\n' '{"code":0,"msg":"成功","data":{"fid":"snapshot-folder","full_path":"夸克网盘/测试备份/snapshot"},"action":"create-folder","type":"result"}'
    else
      printf '%s\n' '{"code":0,"msg":"成功","data":{"fid":"remote-folder","full_path":"夸克网盘/测试备份"},"action":"create-folder","type":"result"}'
    fi
    ;;
  upload)
    printf '%s\n' '{"code":0,"msg":"成功","data":{"fullPath":"夸克网盘/测试备份"},"action":"upload","type":"result"}'
    ;;
  login)
    printf '%s\n' '{"code":0,"msg":"成功","data":{},"action":"login","type":"result"}'
    ;;
  *)
    printf '%s\n' '{"code":0,"msg":"成功","data":{},"action":"test","type":"result"}'
    ;;
esac
SH
  chmod +x "$TEST_ROOT/bin/node"
  export PATH="$TEST_ROOT/bin:$PATH"
}

@test "help works without touching config" {
  run "$APP" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"一键交互式备份工具"* ]]
}

@test "status renders account information on Python 3.11" {
  mkdir -p "$TEST_ROOT/python311-bin"
  ln -s /usr/bin/python3.11 "$TEST_ROOT/python311-bin/python3"
  run env PATH="$TEST_ROOT/python311-bin:$PATH" "$APP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"账号：测试账号"* ]]
  [[ "$output" == *"会员：SVIP"* ]]
  [[ "$output" != *"SyntaxError"* ]]
}

@test "commands continue with an installed CLI when vendor update check is offline" {
  cat > "$QUARK_SKILL_DIR/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$QUARK_SKILL_DIR/scripts/install.sh"
  run "$APP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"账号：测试账号"* ]]
  [[ "$output" == *"更新检查失败"* ]]
}

@test "installer supports curl pipe execution and an offline vendor update check" {
  mkdir -p "$TEST_ROOT/installer-bin" "$TEST_ROOT/installer-skill/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TEST_ROOT/installer-skill/scripts/install.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/installer-skill/scripts/uninstall.sh"
  chmod +x "$TEST_ROOT/installer-skill/scripts/install.sh" "$TEST_ROOT/installer-skill/scripts/uninstall.sh"
  : > "$TEST_ROOT/installer-skill/SKILL.md"
  : > "$TEST_ROOT/installer-skill/scripts/quark-drive.cjs"

  cat > "$TEST_ROOT/installer-bin/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$TEST_ROOT/installer-bin/curl" <<SH
#!/usr/bin/env bash
set -e
out=""
url=""
while ((\$#)); do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
case "\$url" in
  */quark-backup.sh) cp "$APP" "\$out" ;;
  */README.md) printf '# test\n' > "\$out" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TEST_ROOT/installer-bin/apt-get" "$TEST_ROOT/installer-bin/curl"

  run env \
    PATH="$TEST_ROOT/installer-bin:$PATH" \
    QUARK_BACKUP_INSTALL_DIR="$TEST_ROOT/installed" \
    QUARK_BACKUP_HOME="$TEST_ROOT/installer-data" \
    QUARK_SKILL_DIR="$TEST_ROOT/installer-skill" \
    QUARK_BACKUP_LINK="$TEST_ROOT/installer-bin/quark-backup" \
    bash < /opt/quark-backup/install.sh
  [ "$status" -eq 0 ]
  [[ "$output" != *"BASH_SOURCE"* ]]
  [ -x "$TEST_ROOT/installed/quark-backup.sh" ]
  [ -L "$TEST_ROOT/installer-bin/quark-backup" ]
}

@test "installer resolves the current vendor skill URL before downloading" {
  mkdir -p "$TEST_ROOT/installer-bin" "$TEST_ROOT/current-skill/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/current-skill/scripts/install.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/current-skill/scripts/uninstall.sh"
  chmod +x "$TEST_ROOT/current-skill/scripts/install.sh" "$TEST_ROOT/current-skill/scripts/uninstall.sh"
  : > "$TEST_ROOT/current-skill/SKILL.md"
  : > "$TEST_ROOT/current-skill/scripts/quark-drive.cjs"
  python3 - "$TEST_ROOT/current-skill" "$TEST_ROOT/current-skill.zip" <<'PY'
import os, sys, zipfile
source, archive = sys.argv[1:]
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as out:
    for root, _, files in os.walk(source):
        for name in files:
            path = os.path.join(root, name)
            out.write(path, os.path.relpath(path, source))
PY

  cat > "$TEST_ROOT/installer-bin/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$TEST_ROOT/installer-bin/curl" <<SH
#!/usr/bin/env bash
set -e
out=""
url=""
while ((\$#)); do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
case "\$url" in
  */quark-backup.sh) cp "$APP" "\$out" ;;
  */README.md) printf '# test\n' > "\$out" ;;
  *skill_config*) printf '%s\n' '{"data":{"config":{"qkPanVersion":"9.9.9","qkPan":"https://vendor.example/current.zip"}}}' ;;
  https://vendor.example/current.zip) cp "$TEST_ROOT/current-skill.zip" "\$out" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TEST_ROOT/installer-bin/apt-get" "$TEST_ROOT/installer-bin/curl"

  run env \
    PATH="$TEST_ROOT/installer-bin:$PATH" \
    QUARK_BACKUP_INSTALL_DIR="$TEST_ROOT/installed-current" \
    QUARK_BACKUP_HOME="$TEST_ROOT/installer-current-data" \
    QUARK_SKILL_DIR="$TEST_ROOT/installer-current-skill" \
    QUARK_BACKUP_LINK="$TEST_ROOT/installer-bin/quark-backup-current" \
    bash < /opt/quark-backup/install.sh
  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/installer-current-skill/SKILL.md" ]
}

@test "login tightens vendor and runtime authorization config permissions" {
  mkdir -p "$QUARK_SKILL_DIR/hermes" "$QUARK_RUNTIME_DIR/hermes"
  : > "$QUARK_SKILL_DIR/hermes/config.json"
  : > "$QUARK_RUNTIME_DIR/hermes/config.json"
  chmod 644 "$QUARK_SKILL_DIR/hermes/config.json" "$QUARK_RUNTIME_DIR/hermes/config.json"
  run "$APP" login test-authorization-code
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$QUARK_SKILL_DIR/hermes/config.json")" = "600" ]
  [ "$(stat -c %a "$QUARK_RUNTIME_DIR/hermes/config.json")" = "600" ]
}

@test "noninteractive setup writes private JSON and round-trips spaces" {
  mkdir -p "$TEST_ROOT/source with spaces"
  printf x > "$TEST_ROOT/source with spaces/a"
  run "$APP" setup --source "$TEST_ROOT/source with spaces" --remote-dir "测试 备份" --local-dir "$TEST_ROOT/local store" --prefix "nightly backup" --schedule weekly --time 02:15 --weekday 3 --keep-local 1
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$XDG_CONFIG_HOME/quark-backup/config.json")" = "600" ]
  run "$APP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_ROOT/source with spaces"* ]]
  [[ "$output" == *"测试 备份"* ]]
  [[ "$output" == *"上传方式：原文件直接上传（不压缩）"* ]]
  [[ "$output" == *"weekly 02:15（星期 3）"* ]]
  run "$APP" run
  [ "$status" -eq 0 ]
  upload_line=$(grep 'quark-drive.cjs upload' "$NODE_CALLS")
  [[ "$upload_line" == *"$TEST_ROOT/source\\ with\\ spaces"* || "$upload_line" == *"$TEST_ROOT/source with spaces"* ]]
  [[ "$upload_line" == *"--parent-fid snapshot-folder"* ]]
}

@test "legacy version-one config keeps archive mode" {
  mkdir -p "$XDG_CONFIG_HOME/quark-backup"
  cat > "$XDG_CONFIG_HOME/quark-backup/config.json" <<JSON
{
  "version": 1,
  "source_paths": ["$TEST_ROOT/source"],
  "remote_dir": "测试备份",
  "schedule": "off",
  "schedule_time": "03:30",
  "weekday": "0",
  "keep_local": "1",
  "local_dir": "$TEST_ROOT/local",
  "archive_prefix": "legacy"
}
JSON
  run "$APP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"上传方式：压缩包上传"* ]]
}

@test "direct mode uploads source paths without creating an archive" {
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --mode direct --schedule off
  [ "$status" -eq 0 ]
  run "$APP" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"原文件已直接上传"* ]]
  create_calls=$(grep -c 'quark-drive.cjs create-folder' "$NODE_CALLS")
  [ "$create_calls" -eq 2 ]
  upload_line=$(grep 'quark-drive.cjs upload' "$NODE_CALLS")
  [[ "$upload_line" == *"$TEST_ROOT/source"* ]]
  [[ "$upload_line" == *"--parent-fid snapshot-folder"* ]]
  [[ "$upload_line" != *".tar.gz"* ]]
  [ ! -d /var/backups/quark-backup ] || ! compgen -G '/var/backups/quark-backup/*.tar.gz' >/dev/null
}

@test "direct mode accepts multiple source paths" {
  mkdir -p "$TEST_ROOT/second"
  printf second > "$TEST_ROOT/second/file.txt"
  run "$APP" setup --source "$TEST_ROOT/source" --source "$TEST_ROOT/second" --remote-dir 测试备份 --mode direct --schedule off
  [ "$status" -eq 0 ]
  run "$APP" run
  [ "$status" -eq 0 ]
  upload_line=$(grep 'quark-drive.cjs upload' "$NODE_CALLS")
  [[ "$upload_line" == *"$TEST_ROOT/source"* ]]
  [[ "$upload_line" == *"$TEST_ROOT/second"* ]]
}

@test "backup creates archive, uploads it, and keeps local copy" {
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --mode archive --local-dir "$TEST_ROOT/local" --prefix smoke --schedule off --keep-local 1
  [ "$status" -eq 0 ]
  run "$APP" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"备份已上传到 夸克网盘/测试备份"* ]]
  archive=$(printf '%s\n' "$TEST_ROOT"/local/smoke-*.tar.gz)
  [ -f "$archive" ]
  [ "$(stat -c %a "$archive")" = "600" ]
  run tar -tzf "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source/file.txt"* ]]
}

@test "backup removes local copy when keep-local is zero" {
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --mode archive --local-dir "$TEST_ROOT/local" --prefix cleanup --schedule off --keep-local 0
  [ "$status" -eq 0 ]
  run "$APP" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"本地临时压缩包已清理"* ]]
  run bash -c 'compgen -G "$1/cleanup-*.tar.gz" >/dev/null' _ "$TEST_ROOT/local"
  [ "$status" -ne 0 ]
}

@test "setup rejects virtual filesystem sources" {
  run "$APP" setup --source /proc --remote-dir bad --schedule off --keep-local 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"不支持备份虚拟系统目录"* ]]
}

@test "setup rejects local archive directory inside source" {
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir bad --mode archive --local-dir "$TEST_ROOT/source/backups" --schedule off --keep-local 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"递归打包"* ]]
}

@test "schedule replacement is idempotent and disable preserves unrelated lines" {
  cat > "$TEST_ROOT/bin/crontab" <<'SH'
#!/usr/bin/env bash
store="${TEST_CRONTAB:?}"
case "${1:-}" in
  -l) [[ -f "$store" ]] && cat "$store" || exit 1 ;;
  -r) rm -f "$store" ;;
  *) cp "$1" "$store" ;;
esac
SH
  chmod +x "$TEST_ROOT/bin/crontab"
  export TEST_CRONTAB="$TEST_ROOT/crontab"
  printf '5 5 * * * unrelated-command\n' > "$TEST_CRONTAB"
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --schedule daily --time 04:17 --keep-local 0
  [ "$status" -eq 0 ]
  run "$APP" schedule
  [ "$status" -eq 0 ]
  run "$APP" schedule
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# BEGIN QUARK-BACKUP$' "$TEST_CRONTAB")" -eq 1 ]
  grep -q '^5 5 \* \* \* unrelated-command$' "$TEST_CRONTAB"
  run "$APP" disable
  [ "$status" -eq 0 ]
  ! grep -q 'QUARK-BACKUP' "$TEST_CRONTAB"
  grep -q '^5 5 \* \* \* unrelated-command$' "$TEST_CRONTAB"
}
