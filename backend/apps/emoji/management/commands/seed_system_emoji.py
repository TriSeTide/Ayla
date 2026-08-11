"""预置系统表情包（可重复执行，幂等）。

- 系统包 owner=None，is_system=True，全员可见；
- 表情图需管理员先通过 kind=emoji 上传媒体，再在管理后台/接口关联到系统包；
  （本期不内置图片资产，README 已注明。）
"""
from django.core.management.base import BaseCommand

from apps.emoji.services import get_or_create_system_pack


class Command(BaseCommand):
    help = "预置系统表情包（幂等，可重复执行）"

    def handle(self, *args, **options):
        packs = ["默认表情", "常用表情"]
        for name in packs:
            pack = get_or_create_system_pack(name)
            self.stdout.write(f"[emoji] 系统包就绪: {pack.name} (id={pack.id})")
        self.stdout.write("[emoji] 系统表情包 seed 完成（表情图需管理员上传 kind=emoji 媒体后关联）")
