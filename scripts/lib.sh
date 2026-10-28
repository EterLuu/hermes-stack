# shellcheck shell=bash
# scripts/*.sh 共用的函数，由各脚本 source，不单独执行。

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
cd "$STACK_DIR" || exit 1

# shellcheck disable=SC2034  # 颜色变量供 source 本文件的脚本使用
if [ -t 1 ]; then
  C_G=$'\033[1;32m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_B=$'\033[1m' C_0=$'\033[0m'
else
  C_G='' C_Y='' C_R='' C_B='' C_0=''
fi
say()  { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!! %s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sxx %s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# 读取 .env 中的值（以最后一次出现为准，去掉首尾引号）。不 source .env，避免执行其中的内容。
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  local line
  line="$(grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%$'\r'}"
  case "$line" in
    \"*\") line="${line#\"}"; line="${line%\"}" ;;
    \'*\') line="${line#\'}"; line="${line%\'}" ;;
  esac
  printf '%s' "$line"
}

# 写入或替换 .env 中的键。用 awk + ENVIRON 处理，值里有 / & 等字符也安全；保留文件权限。
env_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]} index($0, k"=")==1 {print k"="v; next} {print}' \
      "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

rand_hex() { openssl rand -hex "${1:-16}"; }

# 宿主机时区（IANA 名称），检测不到时返回 UTC
host_tz() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || tz="$(cat /etc/timezone 2>/dev/null || true)"
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime | sed -n 's#.*/zoneinfo/##p')"
  fi
  printf '%s' "${tz:-UTC}"
}

# 列出值里含 $ 但没有用单引号包起来的键。docker compose 会把 $xxx 当成变量替换，
# 例如 PW=abc$def 进入容器后只剩 abc。
env_dollar_keys() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | grep -vE "^[A-Za-z0-9_]+='" | grep -E '=.*\$' | cut -d= -f1 || true
}

# 需要同步到 data/.env 的平台配置与密钥：值非空的 TELEGRAM_*、DISCORD_*、*_API_KEY、*_TOKEN。
# Hermes 网关从 data/.env 读取这些键，而不是容器环境变量（见 scripts/sync_env.py）。
# 每行输出 KEY=VALUE，仅用于通过管道传给容器，不要打印到终端。
hermes_secret_lines() {
  [ -f "$ENV_FILE" ] || return 0
  local k v
  for k in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | tr -d = | sort -u \
             | grep -E '^TELEGRAM_|^DISCORD_|_API_KEY$|_TOKEN$' | grep -vE '^HERMES_DASHBOARD_' || true); do
    v="$(env_get "$k")"
    [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
  done
  return 0
}

# 按 token 判断要启用的平台；不额外维护 enabled 开关。
enabled_platforms() {
  local platform key
  for platform in telegram discord; do
    key="$(printf '%s' "$platform" | tr '[:lower:]' '[:upper:]')"
    [ -z "$(env_get "${key}_BOT_TOKEN")" ] || printf '%s\n' "$platform"
  done
  return 0
}

# 访问策略在构建前校验。Discord 使用数字用户 ID；角色白名单为可选的额外授权。
check_messaging_env() {
  MESSAGING_PROBLEMS=()
  local platform prefix token users k value
  [ -n "$(enabled_platforms)" ] || MESSAGING_PROBLEMS+=("至少配置一个平台：TELEGRAM_BOT_TOKEN 或 DISCORD_BOT_TOKEN")
  while read -r platform; do
    [ -n "$platform" ] || continue
    prefix="$(printf '%s' "$platform" | tr '[:lower:]' '[:upper:]')"
    token="$(env_get "${prefix}_BOT_TOKEN")"
    users="$(env_get "${prefix}_ALLOWED_USERS")"
    [ -n "$users" ] || MESSAGING_PROBLEMS+=("${prefix}_ALLOWED_USERS 为空：请填写可使用 Agent 的数字用户 ID")
    if [ "$platform" = telegram ]; then
      if ! printf '%s' "$token" | grep -qE '^[0-9]{5,}:[A-Za-z0-9_-]{30,}$'; then
        MESSAGING_PROBLEMS+=("TELEGRAM_BOT_TOKEN 格式不对（应形如 123456789:AAH...）")
      fi
      if [ -n "$users" ] && ! printf '%s' "$users" | tr -d ' ' | grep -qE '^-?[0-9]+(,-?[0-9]+)*$'; then
        MESSAGING_PROBLEMS+=("TELEGRAM_ALLOWED_USERS 应填数字用户 ID（从 @userinfobot 获取），多个用逗号分隔")
      fi
    else
      # Discord token 的格式可能变化，只由 REST 检查鉴权结果，不依赖固定长度或分段。
      for k in DISCORD_ALLOWED_USERS DISCORD_ALLOWED_CHANNELS DISCORD_ALLOWED_ROLES; do
        value="$(env_get "$k")"
        if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^[[:space:]]*[1-9][0-9]*[[:space:]]*(,[[:space:]]*[1-9][0-9]*[[:space:]]*)*$'; then
          MESSAGING_PROBLEMS+=("$k 应填正整数 ID，多个用逗号分隔，不能填用户名或 @提及")
        fi
      done
      value="$(env_get DISCORD_HOME_CHANNEL)"
      if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^[1-9][0-9]*$'; then
        MESSAGING_PROBLEMS+=("DISCORD_HOME_CHANNEL 应填单个频道的正整数 ID")
      fi
    fi
  done < <(enabled_platforms)
  return 0
}

# Docker 能分配的 CPU 数（Docker Desktop 下是虚拟机的核数）
docker_ncpu() { docker info --format '{{.NCPU}}' 2>/dev/null || echo 0; }

# compose 的 cpus 超过 Docker 可用核数时容器无法启动（"Range of CPUs is from 0.01 to N"）。
# 把超出的上限调整为可用核数，每调整一项输出一行。
clamp_cpu_limits() {
  local ncpu k v
  ncpu="$(docker_ncpu)"
  [ "${ncpu:-0}" -gt 0 ] 2>/dev/null || return 0
  for k in HERMES_CPU_LIMIT DEVBOX_CPU_LIMIT; do
    v="$(env_get "$k")"
    [ -n "$v" ] || continue
    if awk -v v="$v" -v n="$ncpu" 'BEGIN{exit !(v+0 > n+0)}'; then
      env_set "$k" "$ncpu"
      printf '%s %s→%s\n' "$k" "$v" "$ncpu"
    fi
  done
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

require_running() {
  container_running "$1" || die "容器 $1 未运行。先执行: make up   （日志: docker compose logs ${1#hermes-}）"
}

# 在 hermes 容器里以 hermes 用户执行（与网关进程身份相同，生成的文件属主正确）
hx() { docker exec -u hermes hermes "$@"; }
# 容器内 Hermes 自带的 Python 解释器，可以 import Hermes 模块
# shellcheck disable=SC2034
HERMES_PY=/opt/hermes/.venv/bin/python

compose() { docker compose "$@"; }

# ---------- URL / 模型配置 ----------

# URL 中的主机名（小写，去掉协议、userinfo、端口和路径；支持 [IPv6]）
url_host() {
  local u="${1#*://}"
  u="${u%%/*}"; u="${u##*@}"
  case "$u" in
    \[*) u="${u#[}"; u="${u%%]*}" ;;
    *)   u="${u%%:*}" ;;
  esac
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# URL 中的端口（未写明时按协议返回 80 或 443）
url_port() {
  local scheme="${1%%://*}" u="${1#*://}" p=""
  u="${u%%/*}"; u="${u##*@}"
  case "$u" in
    \[*\]:*) p="${u##*]:}" ;;
    \[*)     p="" ;;
    *:*)     p="${u##*:}" ;;
  esac
  if [ -z "$p" ]; then
    if [ "$scheme" = https ]; then p=443; else p=80; fi
  fi
  printf '%s' "$p"
}

is_loopback_host() {
  case "$1" in localhost|127.*|::1|0.0.0.0) return 0 ;; *) return 1 ;; esac
}

# 主机是否只在本机、局域网、tailnet 或 compose 网络内可达（这类地址不能经外部代理访问）
is_local_host() {
  case "$1" in
    "") return 1 ;;
    localhost|127.*|::1|0.0.0.0) return 0 ;;
    *.local|*.lan|*.internal|*.home.arpa|*.ts.net) return 0 ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    fc*:*|fd*:*|fe80:*) return 0 ;;   # IPv6 ULA / 链路本地
    *.*|*:*) return 1 ;;
    *) return 0 ;;   # 不带点的短主机名：compose 服务名、/etc/hosts、MagicDNS
  esac
}

# 是否 Ollama 端点（compose 里的 ollama 服务，或使用默认端口 11434）
is_ollama_url() {
  [ "$(url_host "$1")" = "ollama" ] || [ "$(url_port "$1")" = "11434" ]
}

# 校验 .env 中的模型变量，问题写入全局数组 MODEL_PROBLEMS（为空表示通过）。
# 对应 Hermes 的限制：上下文不足 64K 会拒绝运行；容器里的 localhost 指容器自身；
# custom 端点只支持 chat_completions 和 anthropic_messages 两种协议。
check_model_env() {
  MODEL_PROBLEMS=()
  local provider model ctx base mode host
  provider="$(env_get STACK_MODEL_PROVIDER | tr '[:upper:]' '[:lower:]')"
  model="$(env_get STACK_MODEL)"
  ctx="$(env_get STACK_CONTEXT_LENGTH)"
  if [ -n "$ctx" ]; then
    if ! printf '%s' "$ctx" | grep -qE '^[0-9]+$'; then
      MODEL_PROBLEMS+=("STACK_CONTEXT_LENGTH 必须是整数 token 数，例如 131072")
    elif [ "$ctx" -lt 64000 ]; then
      MODEL_PROBLEMS+=("STACK_CONTEXT_LENGTH=$ctx：Hermes 要求至少 64000。本地推理服务需要调大上下文：Ollama 用 OLLAMA_CONTEXT_LENGTH，vLLM 用 --max-model-len，llama.cpp 用 -c")
    fi
  fi
  [ -n "$provider" ] || return 0
  if [ "$provider" != "custom" ]; then
    # 不写模型名会沿用 config.yaml 里之前的模型，换 provider 后通常不可用
    [ -n "$model" ] || MODEL_PROBLEMS+=("设置了 STACK_MODEL_PROVIDER=$provider 时也需要设置 STACK_MODEL（模型 ID 以 make model 的列表为准）")
    return 0
  fi

  base="$(env_get STACK_CUSTOM_BASE_URL)"
  mode="$(env_get STACK_CUSTOM_API_MODE)"
  [ -n "$model" ] || MODEL_PROBLEMS+=("provider=custom 需要 STACK_MODEL：端点上的模型 ID（可用 curl <base_url>/models 查看）")
  if [ -z "$base" ]; then
    MODEL_PROBLEMS+=("provider=custom 需要 STACK_CUSTOM_BASE_URL，例如 https://api.example.com/v1")
  elif ! printf '%s' "$base" | grep -qE '^https?://[^/]+'; then
    MODEL_PROBLEMS+=("STACK_CUSTOM_BASE_URL 必须以 http:// 或 https:// 开头：$base")
  else
    host="$(url_host "$base")"
    if is_loopback_host "$host"; then
      MODEL_PROBLEMS+=("STACK_CUSTOM_BASE_URL 使用了 $host，在容器里它指 hermes 容器自身。宿主机上的服务请写 host.docker.internal（如 http://host.docker.internal:11434/v1），并让服务监听 0.0.0.0")
    fi
    case "$base" in
      */chat/completions*|*/messages*|*/responses*)
        MODEL_PROBLEMS+=("STACK_CUSTOM_BASE_URL 只填 API 根地址（通常以 /v1 结尾），不要带 /chat/completions、/messages 或 /responses") ;;
    esac
  fi
  case "$mode" in
    ""|chat_completions|anthropic_messages) ;;
    codex_responses)
      MODEL_PROBLEMS+=("STACK_CUSTOM_API_MODE=codex_responses 不适用于 custom 端点（Hermes 只对 OpenAI 官方接口启用 Responses API）。使用 OpenAI 官方接口请设置 STACK_MODEL_PROVIDER=openai") ;;
    *)
      MODEL_PROBLEMS+=("STACK_CUSTOM_API_MODE 只能是 chat_completions 或 anthropic_messages，留空则自动判断") ;;
  esac
  return 0
}
