"""清理语音房幽灵成员（服务端超时判定，cron 每分钟执行）。

    python manage.py voice_reap_stale_members            # 真正清理并广播
    python manage.py voice_reap_stale_members --dry-run  # 只打印将要清理的成员
    python manage.py voice_reap_stale_members --timeout-seconds 120 --channel-id 1

## 为什么需要它（真因 2）

`apps/voice/services.py::mark_stale_members_left` 早已实现，但**全仓库零调用**：
客户端异常退出（杀进程 / 断网 / 崩溃）时不会 POST `/leave/`，成员关系就永远留在
表里。生产实测频道 1 仍有 67.9 小时前 last_seen 的成员，`VOICE_MEMBER_TIMEOUT_SECONDS`
（生产 120s）形同虚设——房内人数与成员列表长期偏多（证据见
Ayla/.workbuddy/evidence/livekit-udp/P4-WS-热更新-结论.md §8）。

本命令只是这个已有能力的**调度入口**，不新增业务语义：
- 判定口径与 leave 完全同源：`last_seen_at < now - VOICE_MEMBER_TIMEOUT_SECONDS`
  （**严格小于**；恰好等于阈值按未超时处理，保守不误踢）；
- 广播路径复用 `services._apply_member_left`（与正常 leave 逐帧一致）：
  `voice.state left` → 客户端移除成员行 → 按需落库 last_vacant_at → 人数刷新；
- **幂等**：已清理的成员不存在了，重复执行返回 0 人 0 帧（cron 每轮重跑安全）。

## 部署（与 keepalive.sh 同风格，cron 每分钟）

    * * * * * docker exec ayla-backend python manage.py voice_reap_stale_members >> /home/ayerelysia/Elysia/ayla-deploy/logs/voice_reap.log 2>&1

## 纪律

手动启动纪律不冲突：本命令是一次性前台入口，cron 只负责**调度清理**，
不负责拉起任何常驻服务；单实例由 cron 的分钟级串行天然保证（重入由幂等兜底）。
"""
from django.conf import settings
from django.core.management.base import BaseCommand

from apps.voice import services
from apps.voice.models import VoiceChannel


class Command(BaseCommand):
    help = "把超时未心跳的语音房成员标记离开并广播 voice.state left（幂等，可 cron 每分钟）"

    def add_arguments(self, parser):
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="只打印将要清理的成员明细，不改库、不发任何帧",
        )
        parser.add_argument(
            "--timeout-seconds",
            type=int,
            default=None,
            help="超时秒数（默认取 settings.VOICE_MEMBER_TIMEOUT_SECONDS）",
        )
        parser.add_argument(
            "--channel-id",
            type=int,
            default=None,
            help="只处理指定频道（默认扫描全部频道）",
        )

    def handle(self, *args, **options):
        dry_run = options["dry_run"]
        timeout = services.resolve_stale_timeout(options["timeout_seconds"])
        configured = int(settings.VOICE_MEMBER_TIMEOUT_SECONDS)

        channels = VoiceChannel.objects.all().order_by("id")
        if options["channel_id"] is not None:
            channels = channels.filter(pk=options["channel_id"])
            if not channels.exists():
                self.stderr.write(
                    self.style.ERROR(f"[voice] 频道不存在：{options['channel_id']}")
                )
                return

        verb = "将清理" if dry_run else "清理"
        total = 0
        touched_channels = 0
        for channel in channels.iterator(chunk_size=200):
            stale = services.find_stale_members(channel, timeout)
            if not stale:
                continue
            touched_channels += 1
            self.stdout.write(
                f"[voice] 频道 {channel.id}（{channel.name}）{verb} {len(stale)} 人"
                f"（阈值 {timeout}s）"
            )
            for member, silent_seconds in stale:
                user = member.user
                identity = getattr(user, "nickname", "") or getattr(
                    user, "username", ""
                )
                self.stdout.write(
                    f"[voice]   - user_id={user.id} identity={identity!r} "
                    f"last_seen_at={member.last_seen_at.isoformat()} "
                    f"silent={int(silent_seconds)}s"
                )
                if dry_run:
                    continue
                # 与正常 leave 完全相同的路径（services 内部复用 _apply_member_left）
                services.reap_stale_member(channel, member)
            total += len(stale)

        if dry_run:
            self.stdout.write(
                self.style.WARNING(
                    f"[voice] dry-run：将清理 {total} 人（涉及 {touched_channels} 个频道），"
                    f"阈值 {timeout}s（settings={configured}s），未改库未发帧"
                )
            )
            return
        if total == 0:
            self.stdout.write(
                f"[voice] 无超时成员（阈值 {timeout}s，settings={configured}s）"
            )
            return
        self.stdout.write(
            self.style.SUCCESS(
                f"[voice] 已清理 {total} 人（涉及 {touched_channels} 个频道），"
                f"阈值 {timeout}s（settings={configured}s）"
            )
        )
