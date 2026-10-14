"""网关状态诊断。由 scripts/check.sh 在 hermes 容器内调用。

读取网关自己维护的运行状态（gateway_state.json 与进程锁），反映的是当前状态，
不受日志中早先记录的影响。输出每行 "OK|BAD|NOTE<TAB>说明"。
"""
import re
import sys
from collections import deque
from pathlib import Path


def out(level, msg):
    print(f"{level}\t{msg}", flush=True)


try:
    from agent.secret_scope import load_env_file
    from gateway.status import get_running_pid, read_runtime_status, runtime_status_is_stale
    from hermes_constants import get_hermes_home
except Exception as exc:  # 不同 Hermes 版本的内部模块可能不同
    out("NOTE", f"当前 Hermes 版本不支持网关状态检查，已跳过：{exc}")
    sys.exit(0)

home = Path(get_hermes_home())
env = load_env_file(home / ".env")
truthy = lambda v: str(v or "").strip().lower() in {"1", "true", "yes", "on"}

# ---- 密钥：网关从 data/.env 读取 ----
token = (env.get("TELEGRAM_BOT_TOKEN") or "").strip()
allowed = [u.strip() for u in (env.get("TELEGRAM_ALLOWED_USERS") or "").split(",") if u.strip()]
allow_all = truthy(env.get("GATEWAY_ALLOW_ALL_USERS")) or truthy(env.get("TELEGRAM_ALLOW_ALL_USERS"))
if token:
    out("OK", "data/.env 中已设置 TELEGRAM_BOT_TOKEN")
else:
    out("BAD", "data/.env 中没有 TELEGRAM_BOT_TOKEN，网关不会启用 Telegram：运行 make up 同步 .env 中的密钥")
if allowed:
    out("OK", f"白名单用户：{', '.join(allowed)}")
elif allow_all:
    out("NOTE", "已允许所有人使用 bot（GATEWAY_ALLOW_ALL_USERS），任何人都能让 Agent 执行命令")
else:
    out("BAD", "TELEGRAM_ALLOWED_USERS 为空：所有人的消息都会被拒绝（私聊只会收到配对码）")

# ---- 网关进程与心跳 ----
pid = get_running_pid(cleanup_stale=False)
rt = read_runtime_status() or {}
state = rt.get("gateway_state") or "未知"
if not pid:
    reason = rt.get("exit_reason")
    out("BAD", f"网关没有运行（状态 {state}{'，' + str(reason) if reason else ''}）：运行 make restart，并用 make logs 查看原因")
elif runtime_status_is_stale(rt):
    out("BAD", "网关超过 2 分钟没有响应（进程可能卡住）：运行 make restart")
elif state in ("degraded", "startup_failed"):
    out("BAD", f"网关状态为 {state}：用 make logs 查看错误")
else:
    out("OK", f"网关运行中（pid {pid}，{state}）")

# ---- Telegram 连接状态 ----
platforms = rt.get("platforms") if isinstance(rt.get("platforms"), dict) else {}


def current(info):
    """条目是否由当前网关进程写入。网关重启后，未启用的平台可能留有上一个进程的旧条目。"""
    wpid, wst = info.get("writer_pid"), info.get("writer_start_time")
    if wpid is not None and rt.get("pid") is not None and wpid != rt.get("pid"):
        return False
    return wst is None or rt.get("start_time") is None or wst == rt.get("start_time")


tg = {k: v for k, v in platforms.items()
      if isinstance(k, str) and isinstance(v, dict) and (k == "telegram" or k.endswith(":telegram"))
      and current(v)}
if pid and not tg:
    hint = "运行 make up 同步 .env 中的密钥" if not token else "运行 make restart，仍然如此请用 make logs 查看原因"
    out("BAD", f"网关没有启用 Telegram（日志显示 No messaging platforms enabled.）：{hint}")
for key, info in tg.items():
    label = "Telegram" if key == "telegram" else f"Telegram（profile {key.split(':')[0]}）"
    st = info.get("state") or "未知"
    err = str(info.get("error_message") or info.get("error_code") or "").strip()[:200]
    if st == "connected":
        out("OK", f"{label} 已连接")
    elif st in ("connecting", "retrying", "reconnecting"):
        out("NOTE", f"{label} 正在连接或重试{('：' + err) if err else ''}（服务器无法直连 Telegram 时，请设置 TELEGRAM_PROXY 或 HTTPS_PROXY）")
    else:
        if re.search(r"conflict|another process", err, re.I):
            err += "。同一个 bot token 正在别处使用，停止另一处后运行 make restart"
        elif re.search(r"unauthori[sz]ed|token|401", err, re.I):
            err += "。请到 @BotFather 重新获取 token，更新 .env 后运行 make up"
        out("BAD", f"{label} 状态为 {st}{('：' + err) if err else ''}")

# ---- 最近被拒绝的用户：帮助发现白名单填错（填了用户名、带 @ 等）----
log = home / "logs" / "gateway.log"
if log.exists():
    seen = {}
    try:
        with open(log, encoding="utf-8", errors="replace") as fh:
            for line in deque(fh, maxlen=3000):
                m = re.search(r"Unauthorized user: (\S+) \((.*?)\) on telegram", line)
                if m and m.group(1) not in allowed:
                    seen[m.group(1)] = m.group(2)
    except OSError:
        pass
    for uid, name in list(seen.items())[-3:]:
        out("NOTE", f"最近有不在白名单中的用户发来消息：{uid}（{name}）。如果是你本人，把 {uid} 加入 .env 的 TELEGRAM_ALLOWED_USERS 后运行 make up")
