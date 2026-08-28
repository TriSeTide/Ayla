"""
backfill_allowed_groups —— 把「归属群 group FK 非空但白名单为空」的存量内容补齐 allowed_groups。

背景：可见性语义从「group FK 提供群可见」迁移到「群可见性完全由 allowed_groups 白名单决定」
（见 apps/common/visibility.py）。迁移前创建的内容若只有 group FK、没有 allowed_groups，
在删除 group FK 可见性后会对群成员不可见；本命令把这些内容的归属群落为白名单，保持群可见。

幂等：M2M add 去重，已存在白名单的条目跳过；可重复运行。
用法：`python manage.py backfill_allowed_groups`
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "补齐 group 非空但 allowed_groups 为空的存量内容的群白名单"

    def handle(self, *args, **options):
        from apps.boardgame.models import GameRoom
        from apps.live.models import LiveChannel
        from apps.posts.models import Post
        from apps.voice.models import VoiceChannel

        models = [Post, LiveChannel, VoiceChannel, GameRoom]
        total = 0
        for model in models:
            # M2M LEFT JOIN：group 非空且无任何白名单关联的记录（去重）。
            rows = model.objects.filter(
                group__isnull=False, allowed_groups__isnull=True
            ).distinct()
            count = 0
            for obj in rows:
                obj.allowed_groups.add(obj.group_id)
                count += 1
            self.stdout.write(f"{model.__name__}: 补齐 {count} 条")
            total += count
        self.stdout.write(self.style.SUCCESS(f"共补齐 {total} 条群白名单"))
