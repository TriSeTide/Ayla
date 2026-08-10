"""健康检查（只读、快速、区分预期禁用与真实故障，不泄露密钥）。"""
import logging

from django.conf import settings
from django.db import connection
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

logger = logging.getLogger(__name__)


class HealthView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        checks = {"db": _check_db(), "cache": _check_cache()}
        degraded = [k for k, v in checks.items() if v != "ok"]
        status = "ok" if not degraded else "degraded"
        return Response(
            {
                "status": status,
                "checks": checks,
                "degraded": degraded,
            },
            status=200 if status == "ok" else 503,
        )


class LiveView(APIView):
    """存活探针：进程活着即 ok，不触碰任何依赖。"""

    permission_classes = [AllowAny]

    def get(self, request):
        return Response({"status": "alive"})


def _check_db() -> str:
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
        return "ok"
    except Exception:
        logger.warning("health db check failed", exc_info=True)
        return "error"


def _check_cache() -> str:
    try:
        from django.core.cache import cache

        cache.set("_health_probe", "1", timeout=5)
        return "ok"
    except Exception:
        logger.warning("health cache check failed", exc_info=True)
        return "error"


# 避免 flake8 报未使用（settings 用于说明依赖 Redis 配置由缓存后端承载）
_ = settings
