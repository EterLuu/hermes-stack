#!/usr/bin/env bash
# 把 .env 中的平台配置与密钥（TELEGRAM_*、DISCORD_*、*_API_KEY、*_TOKEN）同步到 data/.env，有变化时重启网关。
# 用法：scripts/sync-secrets.sh [--no-restart]
#
# Hermes 网关从 data/.env 读取 bot token、白名单和 API Key，不读取容器环境变量，
# 所以修改 .env 后需要同步。make up、init、configure、update、restore 都会自动运行本脚本。
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
RESTART=1
for a in "$@"; do case "$a" in --no-restart) RESTART=0 ;; *) die "未知参数 $a" ;; esac; done
require_running hermes

# 容器刚创建时，等 Hermes 完成初始化（首次启动会生成 data/.env）
for _ in $(seq 1 30); do [ -f data/config.yaml ] && break; sleep 2; done

out="$(hermes_secret_lines | docker exec -i -u hermes hermes "$HERMES_PY" -c "$(cat "$STACK_DIR/scripts/sync_env.py")" 2>&1)" \
  || die "同步密钥到 data/.env 失败：$(printf '%s' "$out" | tail -n3 | tr '\n' ' ')"

changed=0; errors=0
while IFS=$'\t' read -r act key why; do
  case "$act" in
    set)     printf '  %-52s   %s\n' "data/.env $key" "已更新" ;;
    removed) printf '  %-52s   %s\n' "data/.env $key" "已删除（.env 中已不再设置）" ;;
    error)   errors=$((errors+1)); warn "  data/.env $key 写入失败：$why" ;;
    ok)      changed="$key" ;;
  esac
done <<< "$out"
printf '%s' "$out" | grep -q '^ok' || die "同步密钥到 data/.env 失败：$(printf '%s' "$out" | tail -n3 | tr '\n' ' ')"

if [ "$changed" = 0 ]; then
  printf '  %-52s   %s\n' "data/.env" "与 .env 一致"
elif [ "$RESTART" = 1 ]; then
  say "密钥已更新，重启网关"
  docker exec hermes hermes gateway restart >/dev/null 2>&1 || compose restart hermes >/dev/null 2>&1
fi
[ "$errors" -eq 0 ]
