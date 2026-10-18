"""客户端更新检查 API（挂载在 /api/v1/updates/ 下）。

接口
----
- ``GET /api/v1/updates/check/?channel=stable&platform=windows&arch=x64&version=1.0.0&build=1``
- 公开只读（应用在登录页之前就可能检查更新）；返回内容不包含任何服务器文件系统路径、
  密钥或发布者信息。

失败语义
--------
- 参数不合法 → 400，``code=invalid_request``。
- 清单缺失 → 200 + ``degraded=true, reason=manifest_unavailable``（绝不冒充“已是最新”）。
- 清单损坏 → 503，``code=release_manifest_invalid``（fail-closed，客户端保留旧版本并提示稍后重试）。
"""
import logging

from rest_framework import permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services

logger = logging.getLogger(__name__)


def _single_param(request, name: str, *, default: str = "") -> str:
    values = request.query_params.getlist(name)
    if len(values) > 1:
        raise services.ManifestInvalid(f"{name} 只能提供一次")
    return values[0].strip() if values else default


class UpdateCheckView(APIView):
    """``GET /updates/check/`` —— 返回某平台/渠道的最新发布与下载描述。"""

    permission_classes = [permissions.AllowAny]
    authentication_classes: list = []

    def get(self, request):
        try:
            channel = services.validate_channel(
                _single_param(request, "channel", default=services.DEFAULT_CHANNEL)
            )
            platform = services.validate_platform(_single_param(request, "platform"))
            arch = services.validate_arch(_single_param(request, "arch"))
            version = _single_param(request, "version", default="0.0.0")
            raw_build = _single_param(request, "build", default="0")
            if not platform:
                return _bad_request("platform 必填")
            if len(version) > 64:
                return _bad_request("version 过长")
            if not raw_build.isascii() or not raw_build.isdecimal() or len(raw_build) > 9:
                return _bad_request("build 必须是非负整数")
            build = int(raw_build)
        except services.ManifestInvalid as exc:
            return _bad_request(str(exc))

        try:
            payload = services.build_check_response(
                channel=channel,
                platform=platform,
                arch=arch,
                current_version=version,
                current_build=build,
            )
        except services.ManifestInvalid:
            logger.exception(
                "release manifest invalid: channel=%s platform=%s", channel, platform
            )
            return Response(
                {
                    "code": "release_manifest_invalid",
                    "detail": "发布清单不可用，请稍后重试",
                },
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response(payload, status=status.HTTP_200_OK)


def _bad_request(detail: str) -> Response:
    return Response(
        {"code": "invalid_request", "detail": detail},
        status=status.HTTP_400_BAD_REQUEST,
    )
