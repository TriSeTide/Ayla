"""
run_bridge —— 启动爱莉桥接 SSE 订阅后台循环（明确 owner，AGENTS.md §7）。

用法：
    python manage.py run_bridge [--stream STREAM_ID] [--no-daemon]

设计（步骤文件 §4.5）：
- 加载应用级 ElysiaProfile（缺省取第一个启用的）；
- 用 service credential 换 session → 订阅 GET /events/stream（chat.message.*，
  stream 匹配）→ 逐事件投影落库 + 广播 elysia.reply；
- 断线/错误帧 → 按最后 cursor 重连（有界退避）；history_gap → 按 recovery.cursor；
- SIGTERM/SIGINT → 置 stop_event 优雅关闭（关连接、退出循环）。

真实订阅循环逻辑在 services.run_bridge_loop（供本命令与契约测试共用），
本命令只做进程生命周期与信号处理。
"""
import asyncio
import logging
import signal

from django.core.management.base import BaseCommand

from apps.elysia_bridge import services
from apps.elysia_bridge.elysia_client import ElysiaClient
from apps.elysia_bridge.models import ElysiaProfile
from apps.elysia_bridge.services import (
    ElysiaCredentialManager,
    ProfileNotConfigured,
)

logger = logging.getLogger(__name__)


class Command(BaseCommand):
    help = "启动爱莉桥接 SSE 订阅循环（断线重连 + 优雅关闭）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--stream",
            default=None,
            help="指定爱莉 stream_id（缺省取启用 profile 的第一个）",
        )

    def handle(self, *args, **options):
        from django.conf import settings

        base_url = getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/")
        if not base_url:
            self.stderr.write(self.style.ERROR("ELYSIA_BASE_URL 未配置"))
            raise ProfileNotConfigured("ELYSIA_BASE_URL 未配置")

        profile = self._pick_profile(options.get("stream"))
        if profile is None:
            self.stderr.write(
                self.style.ERROR("未找到启用的爱莉 profile，请先初始化")
            )
            raise ProfileNotConfigured("未找到启用的爱莉 profile")

        client = ElysiaClient(base_url=base_url)
        credentials = ElysiaCredentialManager(
            client=client,
            secret_path=getattr(settings, "ELYSIA_CREDENTIAL_FILE", None),
        )

        stop_event = asyncio.Event()

        def _request_stop(signum, frame):
            self.stdout.write(
                self.style.WARNING(f"收到信号 {signum}，正在优雅关闭桥接…")
            )
            stop_event.set()

        # 注册信号（Windows 下 SIGTERM 不可用，SIGINT 可用）
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            for sig in (signal.SIGINT, getattr(signal, "SIGTERM", None)):
                if sig is None:
                    continue
                try:
                    loop.add_signal_handler(sig, lambda s=sig: _request_stop(s, None))
                except (NotImplementedError, RuntimeError):
                    signal.signal(sig, _request_stop)
        except Exception:
            # 信号注册失败不阻塞启动（测试环境等）
            pass

        self.stdout.write(
            self.style.SUCCESS(
                f"爱莉桥接已启动：stream={profile.stream_id} → {base_url}"
            )
        )
        try:
            loop.run_until_complete(
                services.run_bridge_loop(
                    profile=profile,
                    client=client,
                    credentials=credentials,
                    stop_event=stop_event,
                )
            )
        except ProfileNotConfigured as exc:
            self.stderr.write(self.style.ERROR(f"凭据缺失：{exc}"))
            raise
        except KeyboardInterrupt:
            pass
        finally:
            client.close()
            loop.close()
            self.stdout.write(self.style.SUCCESS("爱莉桥接已退出"))

    def _pick_profile(self, stream_id: str | None) -> ElysiaProfile | None:
        qs = ElysiaProfile.objects.filter(enabled=True)
        if stream_id:
            qs = qs.filter(stream_id=stream_id)
        return qs.select_related("user").first()
