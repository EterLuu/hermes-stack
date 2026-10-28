"""Discord REST 与 intents 检查。在 hermes 容器内运行，不发送消息、不连接 Gateway。

使用 discord.py 与 Hermes 的代理解析，支持 HTTP / SOCKS 代理。
REST 成功只证明 token 和 HTTP 网络可用；在线状态由 gateway_diag.py 检查。
"""
import asyncio
import os


def out(level, msg):
    print(f"{level}\t{msg}", flush=True)


async def check():
    try:
        import discord
        from agent.secret_scope import load_env_file
        from hermes_cli.config import get_env_path
        from gateway.platforms.base import resolve_proxy_url, proxy_kwargs_for_bot
    except ImportError:
        out("BAD", "Discord 诊断缺少 discord.py 或 Hermes 代理接口；检查镜像版本并升级后重试")
        return

    env = load_env_file(get_env_path())
    token = (env.get("DISCORD_BOT_TOKEN") or "").strip()
    if not token:
        out("BAD", "data/.env 中没有 DISCORD_BOT_TOKEN：运行 make up")
        return
    # Hermes 的 data/.env 优先；通用代理仍可来自容器环境。
    for key in ("DISCORD_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"):
        if env.get(key):
            os.environ[key] = env[key]
    try:
        proxy = resolve_proxy_url(platform_env_var="DISCORD_PROXY")
        async with discord.Client(intents=discord.Intents.none(), **proxy_kwargs_for_bot(proxy)) as client:
            await client.login(token)
            out("OK", f"Discord REST 鉴权成功：{client.user.name}（不代表 Gateway 已连接）")
            app = await client.application_info()
            flags = app.flags
            if flags.gateway_message_content or flags.gateway_message_content_limited:
                out("OK", "Discord Message Content Intent 已开启")
            else:
                out("BAD", "Discord Message Content Intent 未开启：Developer Portal → Bot → Privileged Gateway Intents → 开启并保存，再运行 make restart")
            users = [u.strip() for u in (env.get("DISCORD_ALLOWED_USERS") or "").split(",") if u.strip()]
            if env.get("DISCORD_ALLOWED_ROLES") or any(not u.isdecimal() for u in users):
                if flags.gateway_guild_members or flags.gateway_guild_members_limited:
                    out("OK", "Discord Server Members Intent 已开启")
                else:
                    out("BAD", "角色或用户名白名单需要 Server Members Intent：请在 Developer Portal 开启后重启网关")
    except discord.LoginFailure:
        out("BAD", "Discord token 无效（401）：在 Developer Portal 重置 Bot token，更新 .env 后运行 make up")
    except discord.Forbidden:
        out("BAD", "Discord REST 返回 403：检查 Bot 授权与访问权限")
    except discord.HTTPException as exc:
        if exc.status == 429:
            out("NOTE", "Discord REST 被限流（429）：稍后重试；Gateway 连接状态请看网关诊断")
        else:
            out("BAD", f"Discord REST 请求失败（HTTP {exc.status}），检查网络和 Bot 配置")
    except Exception as exc:
        # 不打印异常内容：网络异常可能包含 token、带密码的代理地址等。
        out("BAD", f"Discord REST 检查失败（{type(exc).__name__}）：检查 DISCORD_PROXY / HTTPS_PROXY 和网络")


async def main():
    try:
        await asyncio.wait_for(check(), timeout=25)
    except asyncio.TimeoutError:
        out("NOTE", "Discord REST 检查超过 25 秒：检查代理和网络；Gateway 连接状态请看网关诊断")


if __name__ == "__main__":
    asyncio.run(main())
