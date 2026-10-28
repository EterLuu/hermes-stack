#!/usr/bin/env bash
# 首次部署：检查环境 → 补全 .env 并生成密钥 → 构建并启动 → 写入 Hermes 配置 → 自检。
# 可以重复运行：已有的 .env 值、密钥和数据不会被覆盖。
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

# ---------- 0. 环境检查 ----------
command -v docker >/dev/null     || die "未安装 Docker（请按 Docker 官方文档安装 Docker Engine，不要用 snap 版）"
docker compose version >/dev/null 2>&1 || die "需要 docker compose v2 插件（docker-compose-plugin）"
docker info >/dev/null 2>&1      || die "无法连接 Docker：确认 Docker 已启动，并且当前用户在 docker 组中（或使用 sudo）"
for c in ssh-keygen openssl awk curl; do command -v "$c" >/dev/null || die "缺少命令: $c"; done

if docker info --format '{{.DockerRootDir}}' 2>/dev/null | grep -q '/snap/'; then
  warn "检测到 snap 版 Docker，它的 AppArmor 限制可能导致容器异常，建议改用 Docker 官方安装方式"
fi
server_major="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)"
if [ -n "$server_major" ] && [ "$server_major" -lt 24 ] 2>/dev/null; then
  warn "Docker $server_major.x 版本较旧，构建时可能不支持 host-gateway，建议升级到 24 或更高版本"
fi

# ---------- 1. .env ----------
if [ ! -f "$ENV_FILE" ]; then
  say "生成 .env"
  cp .env.example "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  uid="${SUDO_UID:-$(id -u)}"; gid="${SUDO_GID:-$(id -g)}"
  if [ "$uid" = "0" ]; then uid=1000; gid=1000; warn "以 root 运行：数据目录和 devbox 用户将使用 UID/GID 1000"; fi
  env_set HOST_UID "$uid"
  env_set HOST_GID "$gid"
fi
chmod 600 "$ENV_FILE"

HOST_UID="$(env_get HOST_UID)"; HOST_GID="$(env_get HOST_GID)"
case "$HOST_UID:$HOST_GID" in
  *[!0-9:]*|:*|*:) die ".env 中 HOST_UID/HOST_GID 必须是数字" ;;
esac
[ "$HOST_UID" != 0 ] && [ "$HOST_GID" != 0 ] || die "HOST_UID/HOST_GID 不能为 0（Hermes 不以 root 运行网关）"

# 如果之前直接运行过 docker compose up，data/ 等目录会被 Docker 以 root 身份创建
for d in data data/home workspace secrets; do
  if [ -d "$d" ] && [ ! -w "$d" ]; then
    die "$d 对当前用户不可写（通常是之前直接运行过 docker compose up）。执行 sudo chown -R $(id -u):$(id -g) data workspace secrets 后重新运行"
  fi
done

while read -r line; do
  [ -n "$line" ] && warn "CPU 上限超过本机可用核数，已调整：$line"
done < <(clamp_cpu_limits)

[ -n "$(env_get TZ)" ] || env_set TZ "$(host_tz)"

# 随机密码：只在为空时生成
[ -n "$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)" ] || env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$(rand_hex 16)"
[ -n "$(env_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)" ]   || env_set HERMES_DASHBOARD_BASIC_AUTH_SECRET "$(rand_hex 32)"
[ -n "$(env_get POSTGRES_PASSWORD)" ]                    || env_set POSTGRES_PASSWORD "$(rand_hex 16)"

# ---------- 2. 校验必填项 ----------
check_messaging_env
problems=("${MESSAGING_PROBLEMS[@]}")
for k in $(env_dollar_keys); do
  problems+=("$k 的值含有 \$，docker compose 会把它当成变量替换：请用单引号包起来，如 $k='...'")
done
# 模型变量在构建前校验，避免构建完才发现配置错误
check_model_env
[ ${#MODEL_PROBLEMS[@]} -eq 0 ] || problems+=("${MODEL_PROBLEMS[@]}")
if [ ${#problems[@]} -gt 0 ]; then
  for p in "${problems[@]}"; do warn "$p"; done
  die "请编辑 $ENV_FILE 后重新运行 scripts/init.sh"
fi

has_key=false
for k in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY GEMINI_API_KEY; do
  [ -n "$(env_get "$k")" ] && has_key=true
done
[ -f data/auth.json ] && has_key=true
# custom 端点：有地址即可（本地服务可以不要 Key）
[ "$(env_get STACK_MODEL_PROVIDER | tr '[:upper:]' '[:lower:]')" = "custom" ] && has_key=true
$has_key || warn "未设置模型 API Key：启动后运行 make model 选择 provider 并登录或填写 Key"
if [ "$(env_get STACK_MODEL_PROVIDER | tr '[:upper:]' '[:lower:]')" = "custom" ] \
   && [ "$(url_host "$(env_get STACK_CUSTOM_BASE_URL)")" = "ollama" ]; then
  case ",$(env_get COMPOSE_PROFILES)," in
    *,ollama,*) ;;
    *) die "STACK_CUSTOM_BASE_URL 指向 ollama 服务，但 COMPOSE_PROFILES 里没有 ollama。请在 .env 中设置 COMPOSE_PROFILES=ollama（同时启用数据库时写 db,ollama）" ;;
  esac
fi

# ---------- 3. 目录与密钥 ----------
say "准备目录与 SSH 密钥"
mkdir -p data/home/.ssh data/cache workspace secrets backups
chmod 700 data data/home/.ssh secrets backups
# 挂载的文件不存在时 Docker 会创建同名目录，这里清理掉
[ -d secrets/authorized_keys ] && rmdir secrets/authorized_keys

KEY=data/home/.ssh/devbox_ed25519
if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hermes@agent" -f "$KEY"
fi
chmod 600 "$KEY"

# authorized_keys = Hermes 的公钥 + 你的公钥（当前用户，或 sudo 之前的用户）+ secrets/extra_authorized_keys
user_home="$HOME"
if [ -n "${SUDO_USER:-}" ]; then user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"; fi
{
  cat "$KEY.pub"
  for k in "$user_home"/.ssh/id_ed25519.pub "$user_home"/.ssh/id_ecdsa.pub "$user_home"/.ssh/id_rsa.pub; do
    if [ -f "$k" ]; then cat "$k"; fi
  done
  if [ -f secrets/extra_authorized_keys ]; then
    grep -vE '^[[:space:]]*(#|$)' secrets/extra_authorized_keys || true
  fi
} | awk '!seen[$0]++' > secrets/authorized_keys
chmod 644 secrets/authorized_keys
say "devbox 已授权 $(wc -l < secrets/authorized_keys | tr -d ' ') 个公钥（添加更多：写入 secrets/extra_authorized_keys 后重新运行本脚本）"

if [ "$(id -u)" = "0" ]; then
  chown -R "$HOST_UID:$HOST_GID" data workspace
fi

# ---------- 4. 构建并启动 ----------
say "构建 devbox 镜像（首次需要 5~15 分钟）"
compose build devbox
say "拉取镜像"
compose pull --ignore-buildable
say "启动"
compose up -d

say "等待 Hermes 初始化"
for _ in $(seq 1 90); do
  if container_running hermes && docker exec hermes test -f /opt/data/config.yaml 2>/dev/null; then break; fi
  sleep 2
done
docker exec hermes test -f /opt/data/config.yaml 2>/dev/null \
  || die "Hermes 未能完成初始化，查看日志：docker compose logs hermes"

# ---------- 5. Agent 人设：只在 data/SOUL.md 仍是镜像默认版本时替换 ----------
if docker exec hermes cmp -s /opt/data/SOUL.md /opt/hermes/docker/SOUL.md 2>/dev/null; then
  say "安装 templates/SOUL.md 作为 Agent 人设（原版本保存为 data/SOUL.md.default）"
  cp data/SOUL.md data/SOUL.md.default
  cat templates/SOUL.md > data/SOUL.md
fi

# ---------- 6. Hermes 配置与自检 ----------
"$STACK_DIR/scripts/configure.sh" || warn "部分配置没有写入，请查看上方输出"
sleep 5
"$STACK_DIR/scripts/check.sh" || true

dash_port="$(env_get DASHBOARD_PORT)"; dash_port="${dash_port:-9119}"
ssh_port="$(env_get DEVBOX_SSH_PORT)"; ssh_port="${ssh_port:-2222}"
cat <<EOF

${C_B}部署完成。接下来：${C_0}
  1. 在已配置的 Telegram / Discord 中给 bot 发「你好」，再发 /sethome（Discord 频道中先 @Bot）
  2. 试试：在 devbox 里执行 whoami && node -v && python -V && go version
  3. 还没有选择模型：运行 make model，或在聊天中发 /model
  4. Dashboard：在本地电脑运行 ssh -L ${dash_port}:127.0.0.1:${dash_port} <服务器>，再打开 http://localhost:${dash_port}
     使用 Tailscale 时，也可以在服务器上运行 sudo tailscale serve --bg ${dash_port}
     账号 $(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)，密码见 .env 中的 HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
  5. 进入开发环境：在服务器上运行 make shell（即 ssh -p ${ssh_port} dev@127.0.0.1），或用 VS Code Remote-SSH（见 README）
  6. 定时备份：crontab -e 添加  30 4 * * * ${STACK_DIR}/scripts/backup.sh >/dev/null 2>&1
EOF
