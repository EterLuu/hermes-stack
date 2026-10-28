#!/usr/bin/env bash
# 自检：容器、hermes → devbox SSH、工具链、Hermes 配置、模型、Telegram / Discord、端口暴露、密钥同步、备份。
# 用法：scripts/check.sh [--llm] [--doctor]
#   --llm     实际调用一次模型（消耗少量 token）
#   --doctor  另外运行 hermes doctor
set -uo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
LLM_TEST=0; DOCTOR=0
for a in "$@"; do case "$a" in --llm) LLM_TEST=1 ;; --doctor) DOCTOR=1 ;; *) die "未知参数 $a" ;; esac; done

pass=0; failn=0; warnn=0
ok()   { pass=$((pass+1));  printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
bad()  { failn=$((failn+1)); printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*"; }
note() { warnn=$((warnn+1)); printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
info() { printf '  · %s\n' "$*"; }

[ -f "$ENV_FILE" ] || die "没有找到 .env，请先运行 scripts/init.sh"

echo "${C_B}[容器]${C_0}"
for c in hermes hermes-devbox; do
  if container_running "$c"; then ok "$c 运行中"; else bad "$c 没有运行（查看日志：docker compose logs ${c#hermes-}）"; fi
done
health="$(docker inspect -f '{{.State.Health.Status}}' hermes-devbox 2>/dev/null || true)"
[ "$health" = "healthy" ] && ok "devbox 健康检查通过" || bad "devbox 健康检查状态：${health:-未知}"
restarts="$(docker inspect -f '{{.RestartCount}}' hermes 2>/dev/null || echo 0)"
[ "${restarts:-0}" -lt 3 ] && ok "hermes 重启次数：${restarts}" || note "hermes 已重启 ${restarts} 次，请查看 docker compose logs hermes"
case ",$(env_get COMPOSE_PROFILES)," in
  *,db,*) for c in hermes-postgres hermes-redis; do
            container_running "$c" && ok "$c 运行中" || bad "$c 没有运行"
          done ;;
esac

container_running hermes && container_running hermes-devbox || {
  echo; die "核心容器没有运行，跳过后续检查"; }

echo "${C_B}[hermes → devbox SSH]${C_0}"
# 与网关执行命令的方式相同：hermes 用户、同一把密钥、非登录 shell
SSH=(ssh -i /opt/data/home/.ssh/devbox_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=8 dev@devbox)
if out="$(hx "${SSH[@]}" 'echo ok' 2>&1)" && [ "$(printf '%s' "$out" | tail -n1)" = "ok" ]; then
  ok "SSH 公钥登录成功"
  tools="$(hx "${SSH[@]}" 'for t in git gh node pnpm python uv go cargo docker psql jq rg; do
             if command -v "$t" >/dev/null 2>&1; then printf "%s " "$t"; else printf "!%s " "$t"; fi; done' 2>/dev/null)"
  missing="$(printf '%s' "$tools" | tr ' ' '\n' | grep '^!' | tr -d '!' | tr '\n' ' ' || true)"
  if [ -z "$missing" ]; then ok "工具链齐全（与 Agent 执行命令时的环境一致）"
  else
    case "$missing" in "cargo ") note "未安装 Rust（INSTALL_RUST=false）" ;; *) bad "Agent 的执行环境中缺少：$missing" ;; esac
  fi
  vers="$(hx "${SSH[@]}" 'printf "node %s | %s | %s" "$(node -v)" "$(python -V 2>&1)" "$(go version | cut -d" " -f3)"' 2>/dev/null)"
  [ -n "$vers" ] && ok "版本：$vers"
  hx "${SSH[@]}" 'test -w /workspace && test -w "$HOME"' 2>/dev/null \
    && ok "/workspace 和 ~ 可写" || bad "/workspace 或 ~ 不可写（检查 .env 中的 HOST_UID/HOST_GID）"
  if hx "${SSH[@]}" 'sudo -n true' >/dev/null 2>&1; then ok "dev 可免密 sudo"; else note "dev 没有 sudo 权限（DEV_SUDO=false）"; fi
else
  bad "SSH 登录失败：$(printf '%s' "$out" | tail -n2 | tr '\n' ' ')"
  if printf '%s' "$out" | grep -q 'IDENTIFICATION HAS CHANGED'; then
    note "devbox 的 host key 已变化（devbox-hostkeys 卷被删除过）：运行 docker exec -u hermes hermes ssh-keygen -R devbox"
  else
    note "排查：docker compose logs devbox；检查 secrets/authorized_keys 和 data/home/.ssh/"
  fi
fi

echo "${C_B}[Hermes 配置]${C_0}"
get() { docker exec hermes hermes config get "$1" 2>/dev/null | tail -n1 | tr -d '"'"'"' ' || true; }
b="$(get terminal.backend)"; [ "$b" = "ssh" ] && ok "terminal.backend = ssh" || bad "terminal.backend = '$b'（运行 make configure）"
s="$(get streaming.enabled | tr '[:upper:]' '[:lower:]')"; [ "$s" = "true" ] && ok "streaming.enabled = true" || note "streaming.enabled = '$s'"

echo "${C_B}[模型]${C_0}"
# 由 Hermes 解析实际使用的模型路由；custom 端点还会检查 /models、模型名和上下文窗口
while IFS=$'\t' read -r level msg; do
  case "$level" in OK) ok "$msg" ;; BAD) bad "$msg" ;; NOTE) note "$msg" ;; *) [ -z "$level" ] || note "$level $msg" ;; esac
done < <(docker exec -i -u hermes hermes "$HERMES_PY" - < "$STACK_DIR/scripts/model_diag.py" 2>/dev/null \
         || echo "NOTE	模型诊断没有运行成功（手动运行查看详情：docker exec -i -u hermes hermes $HERMES_PY - < scripts/model_diag.py）")
if [ "$LLM_TEST" = 1 ]; then
  # 实际调用一次模型（消耗少量 token），确认模型名、协议和工具调用格式都被端点接受
  if out="$(timeout 180 docker exec hermes hermes chat -q "只回复两个字母：OK。不要调用任何工具。" --oneshot -Q --max-turns 2 2>&1)"; then
    reply="$(printf '%s' "$out" | tr -d '\r' | grep -vE '^[[:space:]]*$|^session_id:' | tail -n1)"
    ok "模型调用成功，回复：${reply:0:80}"
  else
    bad "模型调用失败：$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -n3 | tr '\n' ' ' | cut -c1-300)"
  fi
fi

echo "${C_B}[消息网关]${C_0}"
check_messaging_env
for problem in "${MESSAGING_PROBLEMS[@]}"; do bad "$problem"; done
platforms=()
while read -r platform; do
  [ -z "$platform" ] || platforms+=("$platform")
done < <(enabled_platforms)
# 读取网关当前状态，REST 成功不能代替 Gateway 在线。
tg_state=unknown
while IFS=$'\t' read -r level msg; do
  case "$level" in
    OK) ok "$msg"; case "$msg" in "Telegram 已连接"*) tg_state=connected ;; esac ;;
    BAD) bad "$msg" ;; NOTE) note "$msg" ;; *) [ -z "$level" ] || note "$level $msg" ;;
  esac
done < <(docker exec -i -u hermes hermes "$HERMES_PY" - "${platforms[@]}" < "$STACK_DIR/scripts/gateway_diag.py" 2>/dev/null \
         || printf 'BAD\t网关诊断运行失败，检查镜像版本并运行 make doctor\n')

echo "${C_B}[Telegram]${C_0}"
token="$(env_get TELEGRAM_BOT_TOKEN)"; tproxy="$(env_get TELEGRAM_PROXY)"
if [ -z "$token" ]; then info "未配置 Telegram，跳过"
else
  resp="$(docker exec -e TOKEN="$token" -e TPROXY="$tproxy" hermes sh -c \
    'curl -sS --max-time 15 ${TPROXY:+-x "$TPROXY"} "https://api.telegram.org/bot${TOKEN}/getMe"' 2>&1 || true)"
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    ok "Bot API 可以访问：@$(printf '%s' "$resp" | sed -n 's/.*"username":"\([^"[:space:]]*\)".*/\1/p')"
  elif printf '%s' "$resp" | grep -q '"error_code":401'; then
    bad "Bot token 无效（401）：请到 @BotFather 重新获取"
  elif [ "$tg_state" = connected ]; then
    note "容器内无法直接访问 api.telegram.org，但网关已连接（Hermes 会自动改用备用地址或代理），通常无需处理"
  else
    bad "无法访问 api.telegram.org：检查 TELEGRAM_PROXY / HTTPS_PROXY 和网络"
  fi
fi

echo "${C_B}[Discord]${C_0}"
if [ -z "$(env_get DISCORD_BOT_TOKEN)" ]; then info "未配置 Discord，跳过"
else
  while IFS=$'\t' read -r level msg; do
    case "$level" in
      OK) ok "$msg" ;; BAD) bad "$msg" ;; NOTE) note "$msg" ;; *) [ -z "$level" ] || note "$level $msg" ;;
    esac
  done < <(docker exec -i -u hermes hermes "$HERMES_PY" - < "$STACK_DIR/scripts/discord_diag.py" 2>/dev/null \
           || printf 'BAD\tDiscord REST 诊断运行失败，检查镜像版本并运行 make doctor\n')
fi

echo "${C_B}[暴露面]${C_0}"
exposed="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '^hermes' | grep -oE '0\.0\.0\.0:[0-9]+|\[::\]:[0-9]+' || true)"
[ -z "$exposed" ] && ok "没有对外开放的端口（只监听 127.0.0.1）" || bad "存在对外开放的端口：$exposed"
dport="$(env_get DASHBOARD_PORT)"; dport="${dport:-9119}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${dport}/" 2>/dev/null || true)"
case "$code" in
  200|301|302|303|307|401) ok "Dashboard 可以在本机访问（HTTP $code，需要登录）" ;;
  *) note "Dashboard http://127.0.0.1:${dport} 返回 '${code:-无响应}'" ;;
esac
# Dashboard 只监听 127.0.0.1，tailnet 内需要通过 tailscale serve 访问
if command -v tailscale >/dev/null 2>&1; then
  ts_url="$(tailscale serve status 2>/dev/null | awk -v p=":${dport}" '
    /^https?:\/\// {url=$1} index($0, p) && url {print url; exit}')"
  if [ -n "$ts_url" ]; then ok "Dashboard 的 Tailscale 地址：$ts_url"
  else info "在 tailnet 内访问 Dashboard：运行 sudo tailscale serve --bg ${dport}，然后打开 tailscale serve status 显示的地址"; fi
fi
perm="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null)"
[ "$perm" = "600" ] && ok ".env 权限 600" || note ".env 权限为 $perm，建议运行 chmod 600 .env"
for k in $(env_dollar_keys); do
  bad "$k 的值含有 \$ 但没有用单引号包起来：docker compose 会把它当成变量替换"
done
ncpu="$(docker_ncpu)"
for k in HERMES_CPU_LIMIT DEVBOX_CPU_LIMIT; do
  v="$(env_get "$k")"
  if [ -n "$v" ] && awk -v v="$v" -v n="${ncpu:-0}" 'BEGIN{exit !(n+0 > 0 && v+0 > n+0)}'; then
    bad "$k=$v 超过 Docker 可用核数 $ncpu，容器将无法重建（运行 make configure 自动调整）"
  fi
done
if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' hermes-devbox | grep -q 'docker.sock'; then
  note "devbox 挂载了 docker.sock：Agent 相当于拥有宿主机 root 权限"
fi

echo "${C_B}[密钥同步]${C_0}"
# 网关从 data/.env 读取密钥；.env 修改后没有同步，网关就仍在使用旧值
if [ -f data/.env ]; then
  # 用 Hermes 自己的解析器读取 data/.env，只比较，不输出值
  drift="$(hermes_secret_lines | docker exec -i -u hermes hermes "$HERMES_PY" -c '
import sys
from agent.secret_scope import load_env_file
from hermes_cli.config import get_env_path
from pathlib import Path
cur = load_env_file(get_env_path())
want = {}
for line in sys.stdin.read().splitlines():
    k, _, v = line.partition("=")
    want[k] = v
state = Path(get_env_path()).parent / ".stack-synced-env"
previous = set(state.read_text().split()) if state.exists() else set()
for k in sorted(set(want) | (previous & set(cur))):
    if (k in want and cur.get(k) != want[k]) or (k not in want and k in cur):
        print(k, end=" ")' 2>/dev/null)" || drift="?"
  if [ "$drift" = "?" ]; then note "无法读取 data/.env 进行比较"
  elif [ -z "$drift" ]; then ok ".env 中的密钥已同步到 data/.env"
  else bad "这些键修改后还没有同步到 data/.env，网关仍在使用旧值：${drift}（运行 make up）"; fi
  # 其它在两处都设置、但取值不同的键：以 data/.env 为准
  conflicts=""
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    case " $drift " in *" $k "*) continue ;; esac
    pv="$(env_get "$k")"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if [ -n "$pv" ] && [ -n "$v" ] && [ "$pv" != "$v" ]; then conflicts="$conflicts $k"; fi
  done < <(grep -E '^[A-Z0-9_]+=' data/.env 2>/dev/null || true)
  [ -z "$conflicts" ] || note "这些键在 data/.env 和 .env 中取值不同，生效的是 data/.env 的值：$conflicts"
else
  note "还没有 data/.env（Hermes 首次启动时会生成）"
fi

echo "${C_B}[备份]${C_0}"
latest="$(ls -1dt backups/*/ 2>/dev/null | head -n1 || true)"
if [ -z "$latest" ]; then note "还没有备份：运行 make backup，并建议加入 crontab 定期执行"
elif [ -n "$(find "$latest" -maxdepth 0 -mtime +7 2>/dev/null)" ]; then note "最近一次备份已超过 7 天：$latest"
else ok "最近一次备份：$latest"; fi

if [ "$DOCTOR" = 1 ]; then
  echo "${C_B}[hermes doctor]${C_0}"
  docker exec hermes hermes doctor || true
fi

echo
printf '%s通过 %d%s  %s警告 %d%s  %s失败 %d%s\n' "$C_G" "$pass" "$C_0" "$C_Y" "$warnn" "$C_0" "$C_R" "$failn" "$C_0"
[ "$failn" -eq 0 ]
