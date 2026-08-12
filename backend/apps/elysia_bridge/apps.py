"""elysia_bridge 应用配置。"""
from django.apps import AppConfig


class ElysiaBridgeConfig(AppConfig):
    name = "apps.elysia_bridge"
    verbose_name = "爱莉桥接"

    def ready(self) -> None:
        """后端进程启动时内嵌启动 SSE 出站投影（run_bridge，单实例文件锁）。"""
        from apps.elysia_bridge.inline import start_bridge_thread

        start_bridge_thread()
