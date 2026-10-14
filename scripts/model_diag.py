"""模型配置诊断。由 scripts/check.sh 在 hermes 容器内调用。

用 Hermes 自己的解析逻辑得出实际使用的端点、协议和密钥状态；对 custom 端点，
再按 Hermes 的代理规则请求 /models，核对模型名和上下文窗口。
输出每行 "OK|BAD|NOTE<TAB>说明"。
"""
from __future__ import annotations

import sys


def emit(level: str, msg: str) -> None:
    print(f"{level}\t{msg}", flush=True)


try:
    from hermes_cli.env_loader import load_hermes_dotenv

    load_hermes_dotenv()
    from hermes_cli.config import load_config
    from hermes_cli.runtime_provider import resolve_runtime_provider
except Exception as exc:  # 不同 Hermes 版本的内部模块可能不同
    emit("NOTE", f"当前 Hermes 版本不支持模型诊断，已跳过（{type(exc).__name__}: {exc}）")
    sys.exit(0)

MIN_CTX = 64_000
cfg = load_config() or {}
mcfg = cfg.get("model") or {}
if isinstance(mcfg, str):
    mcfg = {"default": mcfg}
model = str(mcfg.get("default") or mcfg.get("model") or "").strip()
ctx_cfg = mcfg.get("context_length")

try:
    rt = resolve_runtime_provider()
except Exception as exc:
    emit("BAD", f"模型路由解析失败：{exc}")
    sys.exit(0)

prov = str(rt.get("provider") or "?")
base = str(rt.get("base_url") or "").rstrip("/")
mode = str(rt.get("api_mode") or "?")
key = rt.get("api_key")
if callable(key):
    key_state, key = "动态凭据", ""
elif not key:
    key_state, key = "无", ""
elif key == "no-key-required":
    key_state, key = "未设置（无鉴权）", ""
elif str(key).startswith("${"):
    key_state = "未展开的引用"
else:
    key_state = f"已配置（…{str(key)[-4:]}）"

emit("OK", f"模型路由：{prov} · {mode} · {base or '默认端点'}")
emit("OK" if model else "NOTE", f"模型：{model or '未选择（运行 make model 或在 Telegram 发 /model）'}，密钥：{key_state}")
if str(key).startswith("${"):
    emit("BAD", f"model.api_key 引用的变量没有值：{key}（在 .env 中设置后运行 make up）")
    key = ""

if prov != "custom":
    sys.exit(0)

# ---------------- custom 端点探测 ----------------
if not base:
    emit("BAD", "custom 端点缺少 base_url：在 .env 中设置 STACK_CUSTOM_BASE_URL 后运行 make configure")
    sys.exit(0)
if mcfg.get("api_key") and not key:
    emit("BAD", "config.yaml 设置了 model.api_key，但解析结果为空：检查 .env 中的 STACK_CUSTOM_API_KEY，然后运行 make up")

try:
    from agent.process_bootstrap import _get_proxy_for_base_url

    proxy = _get_proxy_for_base_url(base)
except Exception:
    proxy = None
try:
    from agent.model_metadata import is_local_endpoint

    local = is_local_endpoint(base)
except Exception:
    local = False
if proxy and local:
    emit("BAD", f"本地或内网端点 {base} 会经过代理访问，通常无法连通：把主机名加入 .env 的 NO_PROXY 后运行 make configure")
elif proxy:
    emit("NOTE", "该端点经过代理（HTTPS_PROXY）访问；如果它可以直连，把域名加入 NO_PROXY")

import httpx  # Hermes 的依赖，容器内一定存在

headers = {"User-Agent": "hermes-stack-check"}
if key:
    if mode == "anthropic_messages":
        headers.update({"x-api-key": key, "anthropic-version": "2023-06-01"})
    else:
        headers["Authorization"] = f"Bearer {key}"
if mode == "anthropic_messages":
    # Hermes 会去掉结尾的 /v1，再由 Anthropic SDK 拼接 /v1/messages，所以两种写法等价
    root = base[:-3].rstrip("/") if base.endswith("/v1") else base
    candidates, compare_alt = [root + "/v1"], False
else:
    # OpenAI 兼容接口的请求直接拼在 base_url 后面，/v1 写错会 404，所以两种写法都试一次
    alt = base[:-3].rstrip("/") if base.endswith("/v1") else base + "/v1"
    candidates, compare_alt = [base, alt], True
ids: list[str] | None = None
hit_base, errors, auth_failed, server_error = "", [], False, ""
with httpx.Client(proxy=proxy, timeout=10.0, trust_env=False, follow_redirects=True) as client:
    for candidate in candidates:
        url = candidate + "/models"
        try:
            resp = client.get(url, headers=headers)
        except httpx.ConnectError as exc:
            errors.append(f"{url} 连接失败（{exc}）")
            continue
        except httpx.TimeoutException:
            errors.append(f"{url} 超时")
            continue
        except Exception as exc:
            errors.append(f"{url} {type(exc).__name__}: {exc}")
            continue
        if resp.status_code in (401, 403):
            auth_failed = True
            errors.append(f"{url} 鉴权失败 HTTP {resp.status_code}")
            continue
        if resp.status_code >= 500:
            server_error = server_error or f"{url} HTTP {resp.status_code}"
        if resp.status_code != 200:
            errors.append(f"{url} HTTP {resp.status_code}")
            continue
        try:
            data = resp.json()
            items = data.get("data", data.get("models", [])) if isinstance(data, dict) else data
            ids = [str(i.get("id") or i.get("name") or "") for i in items if isinstance(i, dict)]
            hit_base = candidate
            break
        except Exception:
            errors.append(f"{url} 返回的不是模型列表 JSON")

if ids is not None:
    if compare_alt and hit_base != base:
        emit("BAD", f"base_url 的 /v1 可能写错了：{base}/models 不可用，{hit_base}/models 可用。请把 STACK_CUSTOM_BASE_URL 改为 {hit_base}")
    else:
        emit("OK", f"端点可达：{hit_base}/models 返回 {len(ids)} 个模型")
    if model and ids:
        if model in ids or (":" not in model and f"{model}:latest" in ids):
            emit("OK", f"模型 {model} 在端点列表中")
        else:
            sample = "、".join(ids[:8]) + ("…" if len(ids) > 8 else "")
            emit("BAD", f"模型 {model} 不在端点的模型列表中（区分大小写）。可用的模型：{sample}")
elif auth_failed:
    emit("BAD", "端点拒绝了密钥（401/403）：检查 .env 中的 STACK_CUSTOM_API_KEY，以及 STACK_CUSTOM_API_MODE 是否与端点协议一致")
elif server_error:
    emit("BAD", f"端点返回服务器错误：{server_error}（服务暂时不可用，请稍后重试或联系服务提供方）")
elif errors and all(("连接失败" in e or "超时" in e) for e in errors):
    hint = ""
    if "host.docker.internal" in base:
        hint = "；宿主机上的服务需要监听 0.0.0.0（Ollama 设置 OLLAMA_HOST=0.0.0.0），并在防火墙放行 Docker 网段（如 ufw allow from 172.16.0.0/12）"
    elif "//ollama:" in base:
        hint = "；确认 COMPOSE_PROFILES 包含 ollama，并且 hermes-ollama 正在运行"
    emit("BAD", f"无法连接端点：{errors[0]}{hint}")
else:
    emit("NOTE", f"端点没有提供 /models 列表，无法核对模型名（通常不影响使用）：{'; '.join(errors)[:200]}")

# ---------------- 上下文窗口 ----------------
try:
    from agent.model_metadata import DEFAULT_FALLBACK_CONTEXT, get_model_context_length, is_local_endpoint as _local

    if ctx_cfg:
        level = "OK" if int(ctx_cfg) >= MIN_CTX else "BAD"
        emit(level, f"上下文窗口：{int(ctx_cfg):,}（model.context_length）")
    elif model:
        detected = get_model_context_length(model, base_url=base, api_key=key or "")
        if detected == DEFAULT_FALLBACK_CONTEXT:
            emit("BAD", f"无法获取上下文窗口，Hermes 将按 {DEFAULT_FALLBACK_CONTEXT:,} 处理：请在 .env 中把 STACK_CONTEXT_LENGTH 设为模型的实际窗口")
        else:
            emit("OK" if detected >= MIN_CTX else "BAD", f"上下文窗口（自动获取）：{detected:,}")
    num_ctx = mcfg.get("ollama_num_ctx")
    if num_ctx and _local(base):
        emit("OK" if int(num_ctx) >= MIN_CTX else "BAD", f"Ollama num_ctx：{int(num_ctx):,}")
except Exception as exc:
    emit("NOTE", f"无法检查上下文窗口：{type(exc).__name__}: {exc}")
