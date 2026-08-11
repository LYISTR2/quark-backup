#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${QUARK_BACKUP_INSTALL_DIR:-/opt/quark-backup}"
SCRIPT="$APP_DIR/quark-backup.sh"
LINK="/usr/local/bin/quark-backup"
RAW_BASE="${QUARK_BACKUP_RAW_BASE:-https://raw.githubusercontent.com/LYISTR2/quark-backup/main}"
SKILL_URL="https://pdds.quark.cn/download/stfile/ssyytvtxsstwsu8uo/quarkclouddrive-1.0.11.zip"
REAL_HOME="${SUDO_USER:+$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)}"
REAL_HOME="${REAL_HOME:-$HOME}"
SKILL_DIR="${QUARK_SKILL_DIR:-${QUARK_BACKUP_HOME:-$REAL_HOME/.local/share/quark-backup}/vendor/quarkclouddrive}"

info() { printf '[信息] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行"
command -v apt-get >/dev/null 2>&1 || die "当前安装器仅支持 Debian/Ubuntu"

info "安装依赖……"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs curl unzip python3 tar cron util-linux

source_script="$SOURCE_DIR/quark-backup.sh"
source_readme="$SOURCE_DIR/README.md"
download_tmp=""
if [[ ! -f "$source_script" ]]; then
  info "下载备份工具……"
  download_tmp=$(mktemp -d)
  trap '[[ -z "${download_tmp:-}" ]] || rm -rf "$download_tmp"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 \
    -o "$download_tmp/quark-backup.sh" "$RAW_BASE/quark-backup.sh"
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 \
    -o "$download_tmp/README.md" "$RAW_BASE/README.md"
  source_script="$download_tmp/quark-backup.sh"
  source_readme="$download_tmp/README.md"
fi

if [[ "$source_script" != "$SCRIPT" ]]; then
  info "安装备份工具到 $APP_DIR……"
  install -d -m 0755 "$APP_DIR"
  install -m 0755 "$source_script" "$SCRIPT"
  [[ -f "$source_readme" ]] && install -m 0644 "$source_readme" "$APP_DIR/README.md"
fi

install -d -m 0700 "${QUARK_BACKUP_HOME:-$REAL_HOME/.local/share/quark-backup}"

if [[ ! -f "$SKILL_DIR/SKILL.md" ]]; then
  info "安装夸克网盘 Skill……"
  skill_tmp=$(mktemp -d)
  trap '[[ -z "${download_tmp:-}" ]] || rm -rf "$download_tmp"; [[ -z "${skill_tmp:-}" ]] || rm -rf "$skill_tmp"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 -o "$skill_tmp/skill.zip" "$SKILL_URL"
  python3 - "$skill_tmp/skill.zip" "$SKILL_DIR" <<'PY'
import os, stat, sys, zipfile
archive, out = sys.argv[1:]
with zipfile.ZipFile(archive) as z:
    for item in z.infolist():
        name = item.filename
        norm = os.path.normpath(name)
        mode = (item.external_attr >> 16) & 0xFFFF
        if name.startswith(('/', '\\')) or norm == '..' or norm.startswith('../'):
            raise SystemExit(f'压缩包含不安全路径: {name}')
        if stat.S_ISLNK(mode):
            raise SystemExit(f'压缩包含符号链接: {name}')
    os.makedirs(out, exist_ok=True)
    z.extractall(out)
PY
fi

chmod 0755 "$SKILL_DIR/scripts/install.sh" "$SKILL_DIR/scripts/uninstall.sh"
bash "$SKILL_DIR/scripts/install.sh"
[[ -x "$SCRIPT" ]] || chmod 0755 "$SCRIPT"
ln -sfn "$SCRIPT" "$LINK"

printf '\n安装完成。运行：\n  quark-backup\n\n'
if [[ -t 0 ]]; then
  exec "$LINK"
fi
