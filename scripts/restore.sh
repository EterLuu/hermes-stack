#!/usr/bin/env bash
# 从 backup.sh 生成的备份恢复。当前数据会先改名为 *.before-restore-<时间戳>，不会被删除。
#   scripts/restore.sh backups/<时间戳>                    恢复 data/、.env、secrets/ 和 devbox home
#   scripts/restore.sh backups/<时间戳> --with-workspace   同时恢复 workspace/
#   加 --yes 跳过确认
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

src="${1:-}"; shift || true
[ -n "$src" ] && [ -f "$src/hermes-data.tgz" ] || die "用法：scripts/restore.sh backups/<时间戳> [--with-workspace] [--yes]"
with_ws=false; yes=false
for a in "$@"; do
  case "$a" in --with-workspace) with_ws=true ;; --yes) yes=true ;; *) die "未知参数 $a" ;; esac
done

if ! $yes; then
  printf '将用 %s 覆盖当前的 data/、.env、secrets/%s。继续吗？[y/N] ' "$src" "$($with_ws && echo '、workspace/')"
  read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "已取消"
fi

ts="$(date +%Y%m%d-%H%M%S)"
say "停止服务"
compose stop hermes devbox >/dev/null 2>&1 || true

say "解包到临时目录"
tmp="$(mktemp -d "$STACK_DIR/.restore.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$src/hermes-data.tgz" -C "$tmp"
# 把数据库快照还原为正式文件
find "$tmp/data" -name '*.db.snapshot' | while read -r f; do mv -f "$f" "${f%.snapshot}"; done

for p in data .env secrets; do
  if [ -e "$p" ]; then mv "$p" "$p.before-restore-$ts"; fi
  mv "$tmp/$p" "$p"
done
chmod 600 .env

if $with_ws && [ -f "$src/workspace.tgz" ]; then
  say "恢复 workspace/"
  [ -e workspace ] && mv workspace "workspace.before-restore-$ts"
  tar -xzf "$src/workspace.tgz"
fi

if [ -f "$src/devbox-home.tgz" ]; then
  say "恢复 devbox home 卷"
  docker volume create hermes_devbox-home >/dev/null
  docker run --rm --entrypoint bash -v hermes_devbox-home:/v -v "$STACK_DIR/$src":/in:ro hermes-devbox:local \
    -c 'find /v -mindepth 1 -delete && tar -xzf /in/devbox-home.tgz -C /v' \
    || warn "devbox home 卷恢复失败（如果镜像 hermes-devbox:local 不存在，请先运行 docker compose build devbox）"
fi

say "启动"
compose up -d
for _ in $(seq 1 30); do container_running hermes && break; sleep 2; done
"$STACK_DIR/scripts/sync-secrets.sh" || warn "密钥同步失败，请查看上方输出"
say "恢复完成。原数据保存在 *.before-restore-$ts，确认无误后可以删除。"
"$STACK_DIR/scripts/check.sh" || true
