"""
为 mp4 视频补做 faststart（moov 前置）重排的管理命令。

用法：
    uv run --no-sync python manage.py ensure_video_faststart              # 全量扫描（幂等）
    uv run --no-sync python manage.py ensure_video_faststart --media-id <id>

行为：扫 kind=video 且 mime 为 mp4 家族的 MediaObject，逐个串行执行
services.ensure_video_faststart。已是 faststart 的对象秒级跳过，可重复执行。
"""

from django.core.management.base import BaseCommand

from apps.media import services
from apps.media.models import MediaObject


class Command(BaseCommand):
    help = "为 mp4 视频补做 faststart（moov 前置）重排；幂等可重复执行"

    def add_arguments(self, parser):
        parser.add_argument(
            "--media-id",
            default=None,
            help="只处理指定 media_id（缺省全量扫描 video/mp4）",
        )

    def handle(self, *args, **options):
        media_id = options.get("media_id")
        qs = MediaObject.objects.filter(kind=MediaObject.KIND_VIDEO)
        if media_id:
            qs = qs.filter(media_id=media_id)
        total = 0
        remuxed = 0
        for media in qs.iterator():
            if not services._is_faststart_candidate(media):
                continue
            total += 1
            if services.ensure_video_faststart(media.media_id):
                remuxed += 1
                self.stdout.write(f"remuxed {media.media_id}")
            else:
                self.stdout.write(f"skipped {media.media_id} (already faststart / failed)")
        self.stdout.write(self.style.SUCCESS(f"done: {remuxed}/{total} remuxed"))
