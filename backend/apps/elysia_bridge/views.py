"""
elysia_bridge 视图 —— 爱莉 profile 管理 REST（挂 /api/v1/elysia/）。

权限（步骤文件 §6）：
- GET  /profile/   读取当前配置的爱莉 profile（应用级单例）→ 登录即可；
- POST /profile/   初始化爱莉 profile（绑定 user）→ 系统管理员；
- PATCH/PUT /profile/ 更新 enabled/display_name → 系统管理员；
- POST /profile/:test  通道探测（探测 consumer 是否在线，D-3）→ 系统管理员；
- GET  /bridge/health/ 通道健康（只读、不泄露正文，DEVELOPMENT.zh.md §5）→ 登录即可。

爱莉 profile 是应用级单例（一个应用实例一个爱莉）。用户与爱莉的会话走 M4-2
conversation 逻辑（用户私聊爱莉 = 与爱莉 user 的私聊会话），本视图不建会话。

主体性约束：本视图只管理应用侧映射与开关，不生成/改写爱莉第一人称内容。
"""
import logging

from django.contrib.auth import get_user_model
from rest_framework import permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import services
from .models import ElysiaProfile
from .serializers import ElysiaProfileSerializer

logger = logging.getLogger(__name__)

User = get_user_model()


def _get_singleton() -> ElysiaProfile | None:
    """应用级单例 profile：取第一个（正常应只有一个）。"""
    return ElysiaProfile.objects.select_related("user").first()


class ElysiaProfileView(APIView):
    """爱莉 profile 读写（应用级单例）。"""

    # GET 登录可读；写操作系统管理员
    def get_permissions(self):
        if self.request.method in ("POST", "PUT", "PATCH"):
            return [permissions.IsAuthenticated(), permissions.IsAdminUser()]
        return [permissions.IsAuthenticated()]

    def get(self, request):
        profile = _get_singleton()
        if profile is None:
            return Response(
                {"detail": "爱莉 profile 尚未初始化"},
                status=status.HTTP_404_NOT_FOUND,
            )
        return Response(
            ElysiaProfileSerializer(profile, context={"request": request}).data
        )

    def post(self, request):
        """初始化爱莉 profile：绑定 user。"""
        if _get_singleton() is not None:
            return Response(
                {"detail": "爱莉 profile 已存在；如需修改用 PATCH"},
                status=status.HTTP_409_CONFLICT,
            )
        ser = ElysiaProfileSerializer(
            data=request.data, context={"request": request}
        )
        ser.is_valid(raise_exception=True)
        profile = ser.save()
        # 不再记录 stream_id（字段已删除，REQUIREMENTS §13.4）
        logger.info(
            "elysia profile initialized: user=%s display_name=%s",
            profile.user_id,
            profile.display_name,
        )
        return Response(
            ElysiaProfileSerializer(profile, context={"request": request}).data,
            status=status.HTTP_201_CREATED,
        )

    def patch(self, request):
        profile = _get_singleton()
        if profile is None:
            return Response(
                {"detail": "爱莉 profile 尚未初始化"},
                status=status.HTTP_404_NOT_FOUND,
            )
        ser = ElysiaProfileSerializer(
            profile, data=request.data, partial=True, context={"request": request}
        )
        ser.is_valid(raise_exception=True)
        profile = ser.save()
        # 补齐：爱莉头像/昵称/启用状态变化后，所有显示她的地方都应更新。
        from .services import broadcast_elysia_profile_updated

        broadcast_elysia_profile_updated(profile)
        return Response(
            ElysiaProfileSerializer(profile, context={"request": request}).data
        )

    def put(self, request):
        return self.patch(request)


def _active_connections(profile) -> int:
    """该 profile 的通道当前活跃连接数（探测失败按 0 处理，不 500）。"""
    from .consumers import _active_connections as probe

    return probe(profile.id)


class ElysiaProfileTestView(APIView):
    """POST /profile/:test —— 通道探测（开发/运维）。

    D-3 起语义改为「探测通道是否连通」：数一下该 profile 的通道 group 里有几条
    活跃 WS 连接（DSH 主动拨入的那条）。**不再换发任何凭据**——旧 credential
    链路已随旧桥接整体删除（REQUIREMENTS.zh.md §13）。

    连通 → 200 {ok:true}；未连通 → 503 {ok:false}（不假装连通、也不 500）。
    """

    permission_classes = [permissions.IsAuthenticated, permissions.IsAdminUser]

    def post(self, request):
        profile = _get_singleton()
        if profile is None:
            return Response(
                {"detail": "爱莉 profile 尚未初始化"},
                status=status.HTTP_404_NOT_FOUND,
            )
        if not profile.enabled:
            return Response(
                {"detail": "爱莉 profile 已禁用，先启用再探测"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        active = _active_connections(profile)
        if active <= 0:
            return Response(
                {
                    "ok": False,
                    "active_connections": 0,
                    "detail": "通道未连通：没有 DSH 拨入的活跃连接",
                },
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        return Response(
            {
                "ok": True,
                "profile_id": str(profile.id),
                "active_connections": active,
                "pending": services.pending_count(),
            }
        )


class ElysiaBridgeHealthView(APIView):
    """GET /bridge/health/ —— 通道健康（只读探测，DEVELOPMENT.zh.md §5）。

    返回 `{ok, profile, pending, active_connections}`：
    - `ok`：profile 存在且启用、且通道有活跃连接；
    - `profile`：应用侧身份映射（id / user_id / enabled / display_name），
      **不含**任何凭据或消息正文；
    - `pending`：待投递条数（只给数量，不给内容）；
    - `active_connections`：当前通道连接数。

    无连接时也返回 200（运维要能看到「现在没有连接」这个事实，而不是一个 5xx）。
    """

    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        profile = _get_singleton()
        if profile is None:
            return Response(
                {
                    "ok": False,
                    "profile": None,
                    "pending": 0,
                    "active_connections": 0,
                    "detail": "爱莉 profile 尚未初始化",
                }
            )
        active = _active_connections(profile)
        pending = services.pending_count()
        return Response(
            {
                "ok": bool(profile.enabled) and active > 0,
                "profile": {
                    "id": str(profile.id),
                    "user_id": str(profile.user_id),
                    "enabled": bool(profile.enabled),
                    "display_name": profile.display_name,
                },
                "pending": pending,
                "active_connections": active,
            }
        )
