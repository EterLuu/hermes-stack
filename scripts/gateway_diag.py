"""网关状态诊断。在 hermes 容器内运行，可选参数：telegram discord。

读取 gateway_state.json 与进程锁，避免把历史日志或 REST 成功当成在线。
输出每行 "OK|BAD|NOTE<TAB>说明"；未启用的平台不报错。
"""
import re
import sys
from collections import deque
from pathlib import Path


LABELS = {"telegram": "Telegram", "discord": "Discord"}


def out(level, msg):
    print(f"{level}\t{msg}", flush=True)


def main():
    requested = sys.argv[1:]
    if any(p not in LABELS for p in requested):
        out("BAD", "平台参数只能是 telegram 或 discord")
        return
    try:
        from agent.secret_scope import load_env_file
        from gateway.status import get_running_pid, read_runtime_status, runtime_status_is_stale
        from hermes_constants import get_hermes_home
    except ImportError:
        out("NOTE", "当前 Hermes 版本不支持网关状态检查，运行 make doctor 或升级镜像")
        return

    home = Path(get_hermes_home())
    env = load_env_file(home / ".env")
    enabled = requested or [p for p in LABELS if (env.get(f"{p.upper()}_BOT_TOKEN") or "").strip()]
    if not enabled:
        out("BAD", "没有配置 Telegram 或 Discord：填写 .env 后运行 make up")
    truthy = lambda v: str(v or "").strip().lower() in {"1", "true", "yes", "on"}
    allowed = {}
    for platform in enabled:
        prefix, label = platform.upper(), LABELS[platform]
        if (env.get(f"{prefix}_BOT_TOKEN") or "").strip():
            out("OK", f"data/.env 中已设置 {prefix}_BOT_TOKEN")
        else:
            out("BAD", f"data/.env 中没有 {prefix}_BOT_TOKEN：运行 make up 同步 .env 中的配置")
        allowed[platform] = [u.strip() for u in (env.get(f"{prefix}_ALLOWED_USERS") or "").split(",") if u.strip()]
        if allowed[platform]:
            out("OK", f"{label} 白名单用户：{', '.join(allowed[platform])}")
        elif platform == "discord" and (env.get("DISCORD_ALLOWED_ROLES") or "").strip():
            out("OK", "Discord 已配置角色白名单（需要 Server Members Intent）")
        elif truthy(env.get("GATEWAY_ALLOW_ALL_USERS")) or truthy(env.get(f"{prefix}_ALLOW_ALL_USERS")):
            out("NOTE", f"{label} 已允许所有用户使用 Agent")
        else:
            out("BAD", f"{prefix}_ALLOWED_USERS 为空：请填写数字用户 ID 后运行 make up")

    pid = get_running_pid(cleanup_stale=False)
    rt = read_runtime_status() or {}
    state = rt.get("gateway_state") or "未知"
    if not pid:
        out("BAD", f"网关没有运行（状态 {state}）：运行 make restart，并用 make logs 查看原因")
    elif rt.get("pid") is not None and rt["pid"] != pid:
        out("BAD", "网关状态仍来自旧进程：等待新进程就绪后重新运行 make check")
    elif runtime_status_is_stale(rt):
        out("BAD", "网关心跳已过期（进程可能卡住）：运行 make restart")
    elif state in ("degraded", "startup_failed"):
        out("BAD", f"网关状态为 {state}：用 make logs 查看错误")
    else:
        out("OK", f"网关运行中（pid {pid}，{state}）")

    platforms = rt.get("platforms") if isinstance(rt.get("platforms"), dict) else {}

    def current(info):
        # 重启后可能残留上一个进程写入的条目。
        if not pid or (rt.get("pid") is not None and rt["pid"] != pid):
            return False
        wpid, wst = info.get("writer_pid"), info.get("writer_start_time")
        if wpid is not None and rt.get("pid") is not None and wpid != rt.get("pid"):
            return False
        return wst is None or rt.get("start_time") is None or wst == rt.get("start_time")

    for platform in enabled:
        entries = {k: v for k, v in platforms.items()
                   if isinstance(k, str) and isinstance(v, dict)
                   and (k == platform or k.endswith(f":{platform}")) and current(v)}
        if pid and not entries:
            out("BAD", f"网关没有启用 {LABELS[platform]}：运行 make up；仍无连接时查看 make logs")
        for key, info in entries.items():
            label = LABELS[platform]
            if key != platform:
                label += f"（profile {key.rsplit(':', 1)[0]}）"
            st = info.get("state") or "未知"
            err = str(info.get("error_message") or info.get("error_code") or "").strip()
            # 上游错误可能带有请求 URL，去掉凭据后再输出。
            for k, value in env.items():
                if value and (k.endswith("TOKEN") or k.endswith("API_KEY") or k.endswith("PROXY")):
                    err = err.replace(str(value), "[redacted]")
            err = " ".join(err.split())[:200]
            if st == "connected":
                out("OK", f"{label} 已连接（Gateway）")
            elif st in ("connecting", "retrying", "reconnecting"):
                out("NOTE", f"{label} 正在连接或重试{('：' + err) if err else ''}；检查 {platform.upper()}_PROXY 或 HTTPS_PROXY")
            else:
                if platform == "discord" and re.search(r"4014|privileged|intent", err, re.I):
                    err += "。在 Developer Portal 开启 Message Content Intent；角色或用户名白名单还需要 Server Members Intent"
                elif re.search(r"unauthori[sz]ed|token|401|authentication|credentials", err, re.I):
                    portal = "Discord Developer Portal" if platform == "discord" else "@BotFather"
                    err += f"。请到 {portal} 更新 token 后运行 make up"
                elif platform == "telegram" and re.search(r"conflict|another process", err, re.I):
                    err += "。同一个 token 正在别处使用，停止另一处后运行 make restart"
                elif platform == "discord" and re.search(r"403|50001|50013|missing.access|missing.permissions|forbidden", err, re.I):
                    err += "。检查服务器角色及父分类、频道权限覆盖，尤其是查看频道、创建公开线程和在线程发送消息权限"
                out("BAD", f"{label} 状态为 {st}{('：' + err) if err else ''}")

    log = home / "logs" / "gateway.log"
    if log.exists():
        seen = {}
        try:
            with open(log, encoding="utf-8", errors="replace") as fh:
                for line in deque(fh, maxlen=3000):
                    m = re.search(r"Unauthorized user: (\S+) \((.*?)\) on (telegram|discord)\b", line)
                    if m and m[3] in allowed and m[1] not in allowed[m[3]]:
                        seen[(m[3], m[1])] = True
        except OSError:
            pass
        for platform, uid in list(seen)[-3:]:
            out("NOTE", f"{LABELS[platform]} 最近拒绝了用户 {uid}；若需要授权，检查 {platform.upper()}_ALLOWED_USERS 后运行 make up")


if __name__ == "__main__":
    main()
