"""校验线上发布清单（只读运维命令）：

    python manage.py release_manifest_check --channel stable

退出码 0 = 清单合法；非 0 = 清单缺失/损坏（打印可诊断原因，不打印文件内容）。
"""
from django.core.management.base import BaseCommand, CommandError

from apps.releases import services


class Command(BaseCommand):
    help = "校验 Ayla 客户端发布清单（只读）"

    def add_arguments(self, parser):
        parser.add_argument("--channel", default=services.DEFAULT_CHANNEL)
        parser.add_argument("--platform", default="")
        parser.add_argument("--arch", default="")

    def handle(self, *args, **options):
        channel = options["channel"]
        try:
            manifest = services.load_manifest(channel)
        except services.ManifestError as exc:
            raise CommandError(f"发布清单不可用：{exc}") from exc
        latest = "无"
        if options["platform"]:
            selected = services.select_latest(
                manifest, platform=options["platform"], arch=options["arch"]
            )
            if selected is not None:
                release, artifact = selected
                latest = f"{release['version']}+{release['build']} ({artifact['kind']})"
        self.stdout.write(
            self.style.SUCCESS(
                f"manifest ok: channel={manifest['channel']} "
                f"releases={len(manifest['releases'])} latest={latest}"
            )
        )
