#!/usr/bin/env bash
# 升级：备份 → 拉取新的 Hermes 镜像 → 重建 devbox（更新语言运行时）→ 重启 → 自检。
# Hermes 启动时会自动迁移 config.yaml，并在旁边保留带时间戳的备份。
#   scripts/update.sh            全部升级
#   scripts/update.sh --hermes   只升级 Hermes，不重建 devbox
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

hermes_version() { { docker exec hermes hermes --version 2>/dev/null || true; } | head -n1; }
old="$(hermes_version)"; old="${old:-未知}"
"$STACK_DIR/scripts/backup.sh"

say "拉取镜像"
compose pull --ignore-buildable
if [ "${1:-}" != "--hermes" ]; then
  say "重建 devbox（同时更新 Ubuntu 基础镜像）"
  compose build --pull devbox
fi
say "重启"
compose up -d
docker image prune -f >/dev/null

say "等待网关就绪"
for _ in $(seq 1 30); do container_running hermes && break; sleep 2; done
"$STACK_DIR/scripts/sync-secrets.sh" || warn "密钥同步失败，请查看上方输出"
new="$(hermes_version)"; new="${new:-未知}"
say "Hermes: $old → $new"
"$STACK_DIR/scripts/check.sh" || warn "自检有失败项。如需回退：把 .env 中的 HERMES_TAG 改回旧版本后运行 make up，或用 scripts/restore.sh 恢复备份"
