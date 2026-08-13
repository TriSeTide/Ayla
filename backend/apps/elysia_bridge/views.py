"""
elysia_bridge 视图 —— 爱莉 profile 管理 REST（挂 /api/v1/elysia/）。

权限（步骤文件 §6）：
- GET  /profile/   读取当前配置的爱莉 profile（应用级单例）→ 登录即可；
- POST /profile/   初始化爱莉 profile（绑定 user + stream_id）→ 系统管理员；
- PATCH/PUT /profile/ 更新 enabled/display_name/chat_type/platform → 系统管理员；
- POST /profile/:test  手动触发一次连接冒烟（开发/运维）→ 系统管理员。

爱莉 profile 是应用级单例（一个应用实例一个爱莉）。用户与爱莉的会话走 M4-2
conversation 逻辑（用户私聊爱莉 = 与爱莉 user 的私聊会话），本视图不建会话。

主体性约束：本视图只管理应用侧映射与开关，不生成/改写爱莉第一人称内容。
"""
import logging

from django.contrib.auth import get_user_model
from rest_framework import permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import ElysiaProfile
from .serializers import ElysiaProfileSerializer
from . import services
from .services import ProfileNotConfigured

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
        """初始化爱莉 profile：绑定 user + stream_id。"""
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
        logger.info("elysia profile initialized: stream=%s user=%s",
                    profile.stream_id, profile.user_id)
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
        return Response(
            ElysiaProfileSerializer(profile, context={"request": request}).data
        )

    def put(self, request):
        return self.patch(request)


class ElysiaProfileTestView(APIView):
    """POST /profile/:test —— 连接冒烟（开发/运维）。

    只验证凭据链路与 session 换发，不真正 inject（避免打扰爱莉）。
    返回 stream_id 与 session 状态；凭据未配置时返回 503。
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
                {"detail": "爱莉 profile 已禁用，先启用再冒烟"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        try:
            from .services import get_injector

            injector = get_injector()
            session_status = injector.smoke(profile=profile)
        except ProfileNotConfigured as exc:
            return Response(
                {"detail": str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE
            )
        except Exception as exc:  # 连接/网络错误
            logger.warning("elysia smoke failed: %s", exc)
            return Response(
                {"detail": f"连接失败: {exc}"},
                status=status.HTTP_502_BAD_GATEWAY,
            )
        return Response(
            {"ok": True, "stream_id": profile.stream_id, "session": session_status}
        )


# ---------- 爱莉 Voice Live 编排（M4-5 §5.2 基线方案，挂 /api/v1/elysia/voice-calls/） ----------


def _require_profile():
    """取应用级单例 profile；不存在/未启用 → 抛 ProfileNotConfigured。"""
    from .services import ProfileNotConfigured

    profile = _get_singleton()
    if profile is None:
        raise ProfileNotConfigured("爱莉 profile 尚未初始化")
    if not profile.enabled:
        raise ProfileNotConfigured("爱莉 profile 已禁用")
    return profile


def _voice_error(exc: Exception) -> Response:
    """统一错误映射：未配置/无凭据 → 503；Elysium 侧错误原样透出。"""
    from .services import ProfileNotConfigured

    if isinstance(exc, ProfileNotConfigured):
        return Response({"detail": str(exc)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
    logger.warning("elysia voice-call op failed: %s", exc)
    return Response(
        {"detail": f"Elysium 侧错误: {exc}",
         "code": getattr(exc, "code", None) or "elysia_error"},
        status=status.HTTP_502_BAD_GATEWAY,
    )


class ElysiaVoiceCallView(APIView):
    """POST /api/v1/elysia/voice-calls/ —— 创建/复用爱莉 Voice Live 通话。

    单并发（Voice Live `max_concurrent_sessions=1`）：进程内活跃通话未结束则复用，
    返回 `{"call": {...}, "connection": {...}|null, "reused": bool}`。
    """

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        try:
            profile = _require_profile()
            result = services.ensure_elysia_voice_call(
                profile, mode=request.data.get("mode") or "auto"
            )
        except Exception as exc:
            return _voice_error(exc)
        return Response(
            {
                "call": _call_status_data(result["call"]),
                "connection": (
                    _ticket_data(result["connection"])
                    if result["connection"] is not None
                    else None
                ),
                "reused": result["reused"],
            },
            status=status.HTTP_200_OK,
        )


class ElysiaVoiceCallDetailView(APIView):
    """GET /api/v1/elysia/voice-calls/<call_id>/ —— 通话状态。"""

    permission_classes = [permissions.IsAuthenticated]

    def get(self, request, call_id):
        try:
            profile = _require_profile()
            result = services.get_voice_call_status(profile, call_id)
        except Exception as exc:
            return _voice_error(exc)
        return Response({"call": _call_status_data(result)})


class ElysiaVoiceCallTextView(APIView):
    """POST /api/v1/elysia/voice-calls/<call_id>/text/ —— 向实时会话注入文本
    （真人想对爱莉说的话，M4-5 §5.2 第 4 步；必须带 Idempotency-Key，服务端生成）。"""

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, call_id):
        text = (request.data.get("text") or "").strip()
        if not text:
            return Response(
                {"detail": "text 不能为空"}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            profile = _require_profile()
            result = services.send_voice_text(profile, call_id, text)
        except Exception as exc:
            return _voice_error(exc)
        return Response(
            {
                "command_id": result.command_id,
                "status": result.status,
                "accepted": result.accepted,
            }
        )


class ElysiaVoiceCallEndView(APIView):
    """POST /api/v1/elysia/voice-calls/<call_id>/end/ —— 结束通话（幂等）。"""

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, call_id):
        try:
            profile = _require_profile()
            result = services.end_elysia_voice_call(profile, call_id)
        except Exception as exc:
            return _voice_error(exc)
        return Response(
            {
                "command_id": result.command_id,
                "status": result.status,
                "accepted": result.accepted,
            }
        )


class ElysiaVoiceCallPollView(APIView):
    """POST /api/v1/elysia/voice-calls/<call_id>/poll/ —— 增量转写投影。

    拉取授权转写历史 → 把 `role="assistant"` 的 final transcript 投影为语音频道
    会话里的爱莉消息（幂等 `elysia-voice-<event_id>`，重复轮询不重复落库）。
    返回 `{"projected": [...], "total": n}`。不伪造：没有 final transcript 就没有爱莉发言。
    """

    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, call_id):
        try:
            profile = _require_profile()
            result = services.poll_voice_transcripts(profile, call_id)
        except Exception as exc:
            return _voice_error(exc)
        return Response(result)


def _call_status_data(status) -> dict:
    """VoiceCallStatus → JSON（只暴露安全字段，不泄露密钥/原始音频）。"""
    return {
        "call_id": status.call_id,
        "episode_id": status.episode_id,
        "state": status.state,
        "mode": status.mode,
        "provider": status.provider,
        "created_at": status.created_at,
        "updated_at": status.updated_at,
        "resumable": status.resumable,
        "connected": status.connected,
        "input_audio_bytes": status.input_audio_bytes,
        "output_audio_bytes": status.output_audio_bytes,
        "interruptions": status.interruptions,
        "failure_reason": status.failure_reason,
    }


def _ticket_data(ticket) -> dict:
    """VoiceCallTicket → JSON（WS ticket 信息，不含 ticket secret 细节）。"""
    return {
        "url": ticket.url,
        "resource": ticket.resource,
        "subprotocol": ticket.subprotocol,
        "expires_at": ticket.expires_at,
    }
