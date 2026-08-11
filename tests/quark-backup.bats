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
  cat > "$TEST_ROOT/bin/node" <<'SH'
#!/usr/bin/env bash
cmd="${2:-}"
case "$cmd" in
  get-user-info)
    printf '%s\n' '{"code":0,"msg":"成功","data":{"vipInfo":{"vipType":"SVIP","used":1024,"capacity":2048},"userInfo":{"nickname":"测试账号"}},"action":"get-user-info","type":"result"}'
    ;;
  create-folder)
    printf '%s\n' '{"code":0,"msg":"成功","data":{"fid":"remote-folder","full_path":"夸克网盘/测试备份"},"action":"create-folder","type":"result"}'
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

@test "installer supports curl pipe execution without BASH_SOURCE" {
  mkdir -p "$TEST_ROOT/installer-bin" "$TEST_ROOT/installer-skill/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/installer-skill/scripts/install.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/installer-skill/scripts/uninstall.sh"
  chmod +x "$TEST_ROOT/installer-skill/scripts/install.sh" "$TEST_ROOT/installer-skill/scripts/uninstall.sh"
  : > "$TEST_ROOT/installer-skill/SKILL.md"

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
  [[ "$output" == *"weekly 02:15（星期 3）"* ]]
}

@test "backup creates archive, uploads it, and keeps local copy" {
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --local-dir "$TEST_ROOT/local" --prefix smoke --schedule off --keep-local 1
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
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir 测试备份 --local-dir "$TEST_ROOT/local" --prefix cleanup --schedule off --keep-local 0
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
  run "$APP" setup --source "$TEST_ROOT/source" --remote-dir bad --local-dir "$TEST_ROOT/source/backups" --schedule off --keep-local 0
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
