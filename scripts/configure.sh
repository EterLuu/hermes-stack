#!/usr/bin/env bash
# 把推荐配置写入 Hermes（data/config.yaml），可以重复运行。
#   1. 把 .env 中的密钥同步到 data/.env
#   2. 用 `hermes config set` 写入执行后端、Telegram、时区等推荐设置
#   3. STACK_MODEL_PROVIDER 非空时，按 .env 写入模型设置
#   4. 回读校验，然后重启网关使配置生效
# 想调整某项设置：修改本文件后重新运行，或使用 make config 直接编辑 config.yaml。
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"
require_running hermes

fail=0
say "同步密钥到 data/.env"
"$STACK_DIR/scripts/sync-secrets.sh" --no-restart || fail=1

cfg() {
  local out
  if out="$(docker exec hermes hermes config set "$1" "$2" 2>&1)"; then
    printf '  %-52s = %s\n' "$1" "$2"
    if printf '%s' "$out" | grep -qi "did you mean"; then
      warn "  ↳ $(printf '%s' "$out" | grep -i "did you mean" | head -n1)"
    fi
  else
    fail=1
    warn "  设置失败 $1：$(printf '%s' "$out" | tail -n1)"
  fi
}
cfg_unset() { docker exec hermes hermes config unset "$1" >/dev/null 2>&1 || true; }

say "写入 Hermes 配置"

# --- 执行后端：命令、文件读写、代码执行都在 devbox 里进行 ---
# 网关以 config.yaml 中的 terminal.* 为准，所以即使 compose 已设置环境变量，也要写在这里
cfg terminal.backend          ssh
cfg terminal.ssh_host         devbox
cfg terminal.ssh_user         dev
cfg terminal.ssh_port         22
cfg terminal.ssh_key          /opt/data/home/.ssh/devbox_ed25519
cfg terminal.cwd              /workspace
cfg terminal.persistent_shell true
# 单条命令超时（秒）：安装依赖、编译、跑测试都可能比较久
cfg terminal.timeout          600

# --- Telegram ---
# 流式输出（默认关闭）。edit 表示逐步编辑同一条消息，兼容性最好
cfg streaming.enabled   true
cfg streaming.transport edit
cfg platforms.telegram.extra.disable_link_previews     true
# 网关重启期间收到的消息，重启后照常处理
cfg platforms.telegram.extra.drop_pending_on_cold_boot false

# --- 时区：定时任务按此时区解析 ---
tz="$(env_get TZ)"; cfg timezone "${tz:-UTC}"

# --- 长对话：间隔 30 分钟以上再继续时，先压缩旧上下文 ---
cfg compression.idle_compact_after_seconds 1800

# --- 禁止的命令：即使你批准也不会执行 ---
# 如需放开：删除下面这行，并运行 docker exec hermes hermes config unset approvals.deny
cfg approvals.deny '["*git push*--force*", "*git push* -f*", "*git push*+*"]'

# --- 模型 ---
# STACK_MODEL_PROVIDER 为空：不改动模型配置（由 make model 或 Telegram /model 管理）。
# 非空：model.* 以 .env 为准，.env 没有提供的字段会被清除，避免换模型后残留旧设置。

# 把 custom 端点登记到 custom_providers，之后可以在 Telegram /model 菜单里切回它。
# 端点地址变化时删除之前登记的旧地址（记录在 data/.stack-custom-base-url），避免菜单里堆积。
# 先读取原始 config.yaml 计算新列表，再交给 `hermes config set` 写回：
# 这样只修改 custom_providers 一项，不会把其它默认值写进配置文件。
STACK_CUSTOM_STATE=data/.stack-custom-base-url
register_custom_provider() {
  local out prev="" json
  [ -f "$STACK_CUSTOM_STATE" ] && prev="$(cat "$STACK_CUSTOM_STATE")"
  if out="$(docker exec -i -u hermes hermes "$HERMES_PY" - "$@" "$prev" 2>&1 <<'PY'
import json, sys
base, model, ctx, name, mode, has_key, prev = sys.argv[1:8]
from hermes_cli.config import read_user_config_raw

norm = lambda u: str(u or "").strip().rstrip("/")
cfg = read_user_config_raw() or {}
lst = cfg.get("custom_providers")
lst = [e for e in lst if isinstance(e, dict)] if isinstance(lst, list) else []
if prev and norm(prev) != norm(base):
    lst = [e for e in lst if norm(e.get("base_url")) != norm(prev)]
entry = next((e for e in lst if norm(e.get("base_url")) == norm(base)), None)
if entry is None:
    try:
        from hermes_cli.main_provider_setup import _auto_provider_name
        auto = _auto_provider_name(base)
    except Exception:
        auto = base.split("//")[-1].split("/")[0]
    entry = {"name": name or auto, "base_url": base}
    lst.append(entry)
elif name:
    entry["name"] = name
entry["model"] = model
if has_key == "1":
    entry["key_env"] = "STACK_CUSTOM_API_KEY"
    entry.pop("api_key", None)
else:
    entry.pop("key_env", None)
if mode:
    entry["api_mode"] = mode
else:
    entry.pop("api_mode", None)
models = entry.get("models") if isinstance(entry.get("models"), dict) else {}
if ctx:
    models[model] = {**(models.get(model) or {}), "context_length": int(ctx)}
elif isinstance(models.get(model), dict):
    models[model].pop("context_length", None)
    if not models[model]:
        models.pop(model)
if models:
    entry["models"] = models
else:
    entry.pop("models", None)
print(json.dumps(lst, ensure_ascii=False))
print("ok")
PY
  )" && [ "$(printf '%s' "$out" | tail -n1)" = "ok" ] \
     && json="$(printf '%s\n' "$out" | tail -n2 | head -n1)" \
     && out="$(docker exec hermes hermes config set custom_providers "$json" 2>&1)"; then
    printf '%s' "$1" > "$STACK_CUSTOM_STATE"
    printf '  %-52s   %s\n' custom_providers "已登记（Telegram /model 菜单里可以切回此端点）"
  else
    warn "  登记 /model 菜单项失败（不影响使用）：$(printf '%s' "$out" | tail -n1)"
  fi
}

# 配置了代理时，本地或内网端点必须在 NO_PROXY 中，否则请求会被发往代理。
# 用 Hermes 自己的匹配规则判断（支持 CIDR），不在其中则追加主机名。
ensure_no_proxy() {
  local base="$1" host="$2" cur bypass
  [ -n "$(env_get HTTPS_PROXY)$(env_get HTTP_PROXY)$(env_get ALL_PROXY)" ] || return 0
  is_local_host "$host" || return 0
  cur="$(env_get NO_PROXY)"
  bypass="$(docker exec -e NO_PROXY="$cur" -e no_proxy= hermes "$HERMES_PY" -c \
    'import sys; from agent.proxy_bypass import should_bypass_proxy; print(should_bypass_proxy(sys.argv[1]))' \
    "$base" 2>/dev/null | tail -n1 || true)"
  if [ -z "$bypass" ]; then   # 较早的 Hermes 版本没有该函数，退回按字面匹配
    case ",$cur," in *",$host,"*) bypass=True ;; esac
  fi
  if [ "$bypass" != "True" ]; then
    env_set NO_PROXY "${cur:+$cur,}$host"
    printf '  %-52s   %s\n' NO_PROXY "已追加 $host（本地端点不经过代理），容器重建后生效"
  fi
}

# 端点是本项目的 ollama 服务时，确保模型已经下载
ollama_pull() {
  local base="$1" model="$2"
  [ "$(url_host "$base")" = "ollama" ] || return 0
  if ! container_running hermes-ollama; then
    fail=1; warn "  base_url 指向 ollama 服务，但 hermes-ollama 没有运行：在 .env 的 COMPOSE_PROFILES 中加上 ollama，然后运行 make up"
    return 0
  fi
  if docker exec hermes-ollama ollama show "$model" >/dev/null 2>&1; then
    printf '  %-52s   %s\n' ollama "模型 $model 已存在"
  else
    say "下载 Ollama 模型 $model（耗时取决于模型大小和网络）"
    docker exec hermes-ollama ollama pull "$model" || { fail=1; warn "  下载失败：检查模型名（https://ollama.com/library）和网络连接"; }
  fi
}

configure_model() {
  local provider model ctx base key mode name host
  provider="$(env_get STACK_MODEL_PROVIDER | tr '[:upper:]' '[:lower:]')"
  model="$(env_get STACK_MODEL)"
  ctx="$(env_get STACK_CONTEXT_LENGTH)"
  if [ -z "$provider" ]; then
    say "模型：STACK_MODEL_PROVIDER 为空，保留现有模型配置（用 make model 或 Telegram /model 选择）"
    return 0
  fi
  check_model_env
  if [ ${#MODEL_PROBLEMS[@]} -gt 0 ]; then
    for p in "${MODEL_PROBLEMS[@]}"; do warn "  $p"; done
    fail=1; warn "  模型配置有误，未写入模型设置"
    return 0
  fi

  if [ "$provider" != "custom" ]; then
    say "模型：$provider${model:+ / $model}"
    cfg model.provider "$provider"   # 切换 provider 时 Hermes 会清除旧的 base_url / api_mode
    [ -z "$model" ] || cfg model.default "$model"
    if [ -n "$ctx" ]; then cfg model.context_length "$ctx"; else cfg_unset model.context_length; fi
    # 从 custom 切换回内置 provider 时，清除 custom 专用字段
    for k in base_url api_key key_env api_mode ollama_num_ctx; do cfg_unset "model.$k"; done
    return 0
  fi

  base="$(env_get STACK_CUSTOM_BASE_URL)"; base="${base%/}"
  key="$(env_get STACK_CUSTOM_API_KEY)"
  mode="$(env_get STACK_CUSTOM_API_MODE)"
  name="$(env_get STACK_CUSTOM_NAME)"
  host="$(url_host "$base")"
  say "模型：custom → $base（$model，协议 ${mode:-自动判断}）"
  # 先切换 provider（Hermes 会清理旧 provider 的地址），再写入端点
  cfg model.provider custom
  cfg model.base_url "$base"
  cfg model.default  "$model"
  if [ -n "$key" ]; then
    # 只写引用，Hermes 读取配置时从 data/.env 展开，config.yaml 中不出现明文
    # shellcheck disable=SC2016
    cfg model.api_key '${STACK_CUSTOM_API_KEY}'
  else
    cfg_unset model.api_key
    printf '  %-52s   %s\n' model.api_key "未设置（按无鉴权服务处理）"
  fi
  cfg_unset model.key_env
  if [ -n "$mode" ]; then cfg model.api_mode "$mode"; else cfg_unset model.api_mode; fi
  if is_ollama_url "$base"; then
    # 每次请求都带上 num_ctx，避免 Ollama 使用默认的小上下文
    ctx="${ctx:-$(env_get OLLAMA_CONTEXT_LENGTH)}"; ctx="${ctx:-65536}"
    cfg model.ollama_num_ctx "$ctx"
  else
    cfg_unset model.ollama_num_ctx
  fi
  if [ -n "$ctx" ]; then
    cfg model.context_length "$ctx"
  else
    cfg_unset model.context_length
    warn "  未设置 STACK_CONTEXT_LENGTH：Hermes 会尝试向端点查询，查询不到时按 256K 处理。模型实际窗口更小时请填写"
  fi
  register_custom_provider "$base" "$model" "$ctx" "$name" "$mode" "$([ -n "$key" ] && echo 1 || echo 0)"
  ensure_no_proxy "$base" "$host"
  ollama_pull "$base" "$model"
}
configure_model

# --- 回读关键设置 ---
say "校验"
check_val() {
  local got
  got="$(docker exec hermes hermes config get "$1" 2>/dev/null | tail -n1 | tr -d '"'"'"' ' || true)"
  if [ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" = "$2" ]; then
    printf '  ✓ %s = %s\n' "$1" "$got"
  else
    fail=1; warn "  ✗ $1 应为 $2，实际为 '${got}'"
  fi
}
check_val terminal.backend  ssh
check_val terminal.ssh_host devbox
check_val streaming.enabled true

docker exec hermes hermes config check 2>&1 | grep -vE '^[[:space:]]+○' || true

say "应用配置"
while read -r line; do
  [ -n "$line" ] && warn "CPU 上限超过本机可用核数，已调整：$line"
done < <(clamp_cpu_limits)
# .env 有变化（例如追加了 NO_PROXY、调整了 CPU 上限）时 compose 会重建容器，新容器直接读取新配置；
# 容器没有重建时才需要重启网关。
id_before="$(docker inspect -f '{{.Id}}' hermes 2>/dev/null || true)"
compose up -d --no-build >/dev/null 2>&1 || { fail=1; warn "docker compose up -d 失败，请手动运行查看原因"; }
for _ in $(seq 1 30); do container_running hermes && break; sleep 2; done
if [ "$(docker inspect -f '{{.Id}}' hermes 2>/dev/null || true)" = "$id_before" ]; then
  docker exec hermes hermes gateway restart >/dev/null 2>&1 || compose restart hermes >/dev/null 2>&1
else
  printf '  %s\n' "hermes 容器已按新的 .env 重建"
fi
exit "$fail"
