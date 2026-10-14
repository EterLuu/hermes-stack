#!/usr/bin/env bash
# 备份 Hermes 的全部状态（配置、密钥、会话、记忆、skills、定时任务）和 devbox 的 home 卷。
#   scripts/backup.sh                    常规备份
#   scripts/backup.sh --with-workspace   同时打包 workspace/（不含 node_modules、.venv、target）
# 保留最近 14 份，可用环境变量 KEEP 调整。
# 定时备份：crontab -e 添加  30 4 * * *  /path/to/hermes-stack/scripts/backup.sh >/dev/null 2>&1
# 恢复：scripts/restore.sh backups/<时间戳>
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

KEEP="${KEEP:-14}"
out="backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
chmod 700 backups

tar_excludes=(--exclude='data/cache' --exclude='data/installs' --exclude='*.sock')

if container_running hermes; then
  # Hermes 运行中：用 SQLite 在线备份生成一致的快照 *.db.snapshot，打包时跳过正在使用的数据库文件
  say "生成数据库快照"
  if docker exec -i -u hermes hermes python3 - <<'PY'
import pathlib, sqlite3, sys
root = pathlib.Path("/opt/data")
skip = {"cache", "installs"}
n = 0
for db in root.rglob("*.db"):
    if skip & set(db.relative_to(root).parts):
        continue
    snap = db.with_name(db.name + ".snapshot")
    try:
        src = sqlite3.connect(str(db), timeout=30)
        dst = sqlite3.connect(snap)
        src.backup(dst)
        dst.close(); src.close(); n += 1
    except sqlite3.Error as e:
        print(f"  跳过 {db}: {e}", file=sys.stderr)
print(f"  已生成 {n} 个数据库快照")
PY
  then
    tar_excludes+=(--exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm')
  else
    warn "生成快照失败，改为直接打包数据库文件（可能不是最新的一致状态）"
  fi
else
  say "hermes 没有运行，直接打包数据文件"
fi

# 文件在打包过程中有变化（如日志正在写入）时 GNU tar 返回 1，可以忽略；大于 1 才是错误
safe_tar() { local rc=0; tar "$@" || rc=$?; [ "$rc" -le 1 ] || die "tar 失败 (rc=$rc)"; }

say "打包 data/、.env 和 secrets/"
safe_tar "${tar_excludes[@]}" -czf "$out/hermes-data.tgz" data .env secrets
find data -name '*.db.snapshot' -delete 2>/dev/null || true

vol=hermes_devbox-home
if docker volume inspect "$vol" >/dev/null 2>&1; then
  say "打包 devbox home 卷"
  docker run --rm --entrypoint tar -v "$vol":/v:ro -v "$STACK_DIR/$out":/out hermes-devbox:local \
    --exclude='./.cache' -czf /out/devbox-home.tgz -C /v . \
    || warn "devbox home 卷备份失败"
fi

if [ "${1:-}" = "--with-workspace" ]; then
  say "打包 workspace/"
  safe_tar --exclude='node_modules' --exclude='.venv' --exclude='target' --exclude='__pycache__' \
      -czf "$out/workspace.tgz" workspace
fi

chmod -R go-rwx "$out"
# 只保留最近 KEEP 份
ls -1dt backups/*/ 2>/dev/null | tail -n +"$((KEEP+1))" | while read -r d; do rm -rf "$d"; done
say "备份完成：$out（$(du -sh "$out" | cut -f1)）"
