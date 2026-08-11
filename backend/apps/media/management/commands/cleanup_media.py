"""清理过期上传会话/孤儿临时对象（可选运维命令，步骤文件 2 目录）。

继承 Elysium 手动启动纪律：不引入后台调度，运维手动/计划任务执行即可。
"""
import logging

from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.media.models import MediaUploadSession
from apps.media import storage

logger = logging.getLogger(__name__)


class Command(BaseCommand):
    help = "清理过期上传会话与孤儿临时对象"

    def add_arguments(self, parser):
        parser.add_argument("--no-delete", action="store_true", help="仅列出，不删除")

    def handle(self, *args, **options):
        now = timezone.now()
        expired = MediaUploadSession.objects.filter(
            status=MediaUploadSession.STATUS_PENDING, expires_at__lt=now
        )
        store = storage.get_storage()
        count = 0
        for session in expired[:500]:
            count += 1
            key = storage.tmp_key(session.upload_id)
            if store.exists(key):
                self.stdout.write(f"[media] 清理临时对象 {key}")
                if not options["no_delete"]:
                    store.delete(key)
            if not options["no_delete"]:
                session.status = MediaUploadSession.STATUS_EXPIRED
                session.save(update_fields=["status"])
        self.stdout.write(f"[media] 已处理 {count} 个过期上传会话")
