"""
voice_observer —— 爱莉 Voice Live 通话的 observer WS 订阅（事件驱动，替代前端 5s/10s 轮询）。

背景（README 公共契约缺口）：`voice_call.*` SSE 事件流未进 Elysium Life Event 账本，
`events/stream` 收不到 voice_call 事件；Elysium 提供 per-call observer WebSocket
（`/api/v1/voice-calls/<call_id>/observe`，ticket role=observer）可实时接收
state / transcript / ended / error 事件。本模块用该通道把通话状态与转写增量事件化：

- state / ended / error → 补拉 `GET /voice-calls/<call_id>/` 完整状态
  → 广播 `elysia.voice.call.status` 帧（channels 组 `elysia_voice`）→ 前端面板即时更新；
- transcript（is_final, role=assistant）→ 投影为爱莉消息（幂等 `elysia-voice-<event_id>`，
  与 poll 共用投影逻辑）→ 广播 `elysia.voice.projected` 帧（携带累计投影数）→
  前端「已投影 N 条」即时更新；
- 断线重连：有界退避 + 重新签发单次 ticket；通话终态（ended/failed）停止观察。

生命周期（AGENTS.md §7 owner/并发）：
- `ensure_observing`：幂等启动 daemon 线程（单并发，同一时刻至多观察一个通话）；
- `stop_observing`：显式停止（结束通话时调用）；进程退出线程随之终止。

不伪造（AGENTS.md §4.1）：转写投影只接受 observer 帧里 `role="assistant"` 的
final transcript，文本原样投影；`role="user"` / partial 不落库。
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
from typing import Any

from channels.db import database_sync_to_async
from channels.exceptions import ChannelFull
from channels.layers import get_channel_layer
from django.conf import settings

logger = logging.getLogger(__name__)

# observer WS 订阅组：所有 chat WS 连接加入（ChatConsumer connect 时 group_add）
OBSERVER_GROUP = "elysia_voice"
# Elysium voice-call observer subprotocol（src/app/api/v1/voice_calls.py 常量）
OBSERVER_SUBPROTOCOL = "elysium.voice-call.observer.v1"
# observer ticket 绑定的 Origin（Elysium auth_store 对 ticket.origin 做字符串
# 相等校验；Ayla 后端无浏览器 Origin，用固定标识并在连接时透传同一值）
OBSERVER_ORIGIN = "ayla://bridge"
# 断线重连有界退避（秒）
OBSERVER_RECONNECT_BASE = 3.0
OBSERVER_RECONNECT_MAX = 30.0

_observer_lock = threading.Lock()
_observing_call_id: str | None = None
_observer_thread: threading.Thread | None = None
_observer_stop: threading.Event | None = None


def ensure_observing(profile, call_id: str) -> None:
    """幂等启动通话 observer 订阅（单并发：同一时刻至多观察一个通话）。

    profile：启用中的 ElysiaProfile（仅取 pk/stream_id，线程内重新查避免跨线程
    ORM 连接复用）；call_id：Elysium 侧通话 id。通话终态由 observer 事件自动退出。
    settings.VOICE_OBSERVER_ENABLED=False（测试/禁用）时跳过，不启动后台线程。
    """
    if not getattr(settings, "VOICE_OBSERVER_ENABLED", True):
        logger.debug("voice observer skipped: VOICE_OBSERVER_ENABLED=False")
        return
    global _observer_thread, _observer_stop, _observing_call_id
    with _observer_lock:
        if (
            _observer_thread is not None
            and _observer_thread.is_alive()
            and _observing_call_id == call_id
        ):
            return  # 已在观察该通话
        if _observer_thread is not None and _observer_thread.is_alive():
            _observer_stop.set()  # 换通话：先停旧观察
        _observing_call_id = call_id
        stop = threading.Event()
        thread = threading.Thread(
            target=_observer_main,
            args=(profile.pk, profile.stream_id, call_id, stop),
            name=f"elysia-voice-observer-{call_id}",
            daemon=True,
        )
        _observer_stop = stop
        _observer_thread = thread
        thread.start()
        logger.info("voice observer started for call %s", call_id)


def stop_observing(call_id: str | None = None) -> None:
    """显式停止观察（结束/重建通话时调用）；幂等。call_id 为空时停止任意观察。"""
    global _observer_stop
    with _observer_lock:
        if _observer_stop is not None and (
            call_id is None or _observing_call_id == call_id
        ):
            _observer_stop.set()


# ---------- 线程体 ----------


def _observer_main(profile_id: int, stream_id: str, call_id: str, stop_event) -> None:
    """daemon 线程体：独立事件循环跑 observer 订阅；异常/终态退出由上层处理。"""
    from .models import ElysiaProfile

    profile = (
        ElysiaProfile.objects.filter(pk=profile_id, enabled=True)
        .select_related("user")
        .first()
    )
    if profile is None:
        logger.warning(
            "voice observer skipped: profile %s missing/disabled (call %s)",
            profile_id,
            call_id,
        )
        return
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_observer_loop(profile, call_id, stop_event))
    except Exception:  # noqa: BLE001 - 观察线程异常不击穿 server
        logger.exception("voice observer loop crashed for call %s", call_id)
    finally:
        loop.close()
    logger.info("voice observer stopped for call %s", call_id)


async def _observer_loop(profile, call_id: str, stop_event) -> None:
    """订阅主循环：连接 → 消费事件 → 断线有界退避重连；终态返回。"""
    backoff = OBSERVER_RECONNECT_BASE
    while not stop_event.is_set():
        try:
            terminal = await _observe_once(profile, call_id, stop_event)
            if terminal:
                return  # 通话终态，停止观察
        except Exception as exc:  # noqa: BLE001 - 单次连接失败走退避重连
            logger.warning("voice observer error for call %s: %s", call_id, exc)
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=backoff)
        except asyncio.TimeoutError:
            pass
        backoff = min(backoff * 2, OBSERVER_RECONNECT_MAX)


# ---------- 单次观察连接 ----------


async def _observe_once(profile, call_id: str, stop_event) -> bool:
    """连接一次 observer WS 并消费事件；返回 True = 通话终态（应退出观察）。"""
    import websockets

    from .elysia_client import ElysiaClient
    from .services import ElysiaCredentialManager

    base_url = getattr(settings, "ELYSIA_BASE_URL", "").rstrip("/")
    client = ElysiaClient(base_url=base_url)
    credentials = ElysiaCredentialManager(
        client=client,
        secret_path=getattr(settings, "ELYSIA_CREDENTIAL_FILE", None),
    )
    try:
        access_token = await database_sync_to_async(credentials.ensure_session)(
            stream_id=profile.stream_id
        )
        ticket = await database_sync_to_async(client.issue_voice_call_ticket)(
            access_token=access_token,
            call_id=call_id,
            role="observer",
            origin=OBSERVER_ORIGIN,
        )
        ws_url = _observer_ws_url(base_url, call_id, ticket.ticket)
        async with websockets.connect(
            ws_url,
            subprotocols=[OBSERVER_SUBPROTOCOL],
            additional_headers={"Origin": OBSERVER_ORIGIN},
            open_timeout=10,
            close_timeout=5,
            ping_interval=20,
            ping_timeout=20,
        ) as ws:
            async for raw in ws:
                if stop_event.is_set():
                    return False
                try:
                    frame = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if not isinstance(frame, dict):
                    continue
                if await _handle_observer_frame(profile, call_id, frame):
                    return True
        return False  # 连接正常关闭（服务端会话结束等）→ 重连观察
    finally:
        client.close()


def _observer_ws_url(base_url: str, call_id: str, ticket: str) -> str:
    """api base（http/https）→ ws://host/api/v1/voice-calls/<call_id>/observe?ticket=..."""
    ws_base = (
        base_url.rstrip("/")
        .replace("https://", "wss://", 1)
        .replace("http://", "ws://", 1)
    )
    return f"{ws_base}/api/v1/voice-calls/{call_id}/observe?ticket={ticket}"


# ---------- 事件分派 ----------


async def _handle_observer_frame(profile, call_id: str, frame: dict[str, Any]) -> bool:
    """处理一条 observer 事件帧；返回 True = 通话终态（停止观察）。"""
    ftype = frame.get("type")
    if ftype == "observer.ready":
        # 连接建立（含重连）：快照可能已带最新状态，广播一次让前端对账兜底
        await _broadcast_call_status(profile, call_id)
        return False
    if ftype == "state":
        await _broadcast_call_status(profile, call_id)
        return False
    if ftype == "transcript":
        text = (frame.get("text") or "").strip()
        if frame.get("is_final") and frame.get("role") == "assistant" and text:
            from .elysia_client import VoiceTranscriptEntry
            from .services import aproject_voice_transcript

            # observer 帧无 sequence/occurred_at；event_id 与幂等键 `elysia-voice-<hash>` 同源
            entry = VoiceTranscriptEntry(
                role="assistant",
                text=text,
                provider_event_id=str(frame.get("event_id") or ""),
            )
            event_id = str(frame.get("event_id") or f"voice-observe-{call_id}")
            try:
                await aproject_voice_transcript(
                    profile, call_id, entry, event_id=event_id
                )
            except Exception:  # noqa: BLE001 - 单条投影失败不击穿观察连接
                logger.exception(
                    "voice observer transcript projection failed for call %s", call_id
                )
            total = await database_sync_to_async(_voice_projected_total)(profile)
            await _broadcast_projected(call_id, total)
        return False
    if ftype == "ended":
        await _broadcast_call_status(profile, call_id)
        return True  # 通话终态 → 停止观察
    if ftype == "error":
        await _broadcast_call_status(profile, call_id)
        return bool(frame.get("fatal"))  # 致命错误 → 停止观察
    return False


def _voice_projected_total(profile) -> int:
    """该语音会话中已投影的爱莉语音消息数（幂等键前缀 `elysia-voice-` 统计）。"""
    from .services import voice_projected_total

    return voice_projected_total(profile)


def _voice_call_status_data(status) -> dict:
    """VoiceCallStatus → JSON（与 views._call_status_data 同构，仅暴露安全字段）。"""
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


# ---------- 广播（channels 组 elysia_voice，ChatConsumer 已加入） ----------


async def _broadcast_call_status(profile, call_id: str) -> None:
    """observer 状态事件 → 补拉完整通话状态 → 广播 elysia.voice.call.status 帧。"""
    from .services import get_voice_call_status

    try:
        status = await database_sync_to_async(get_voice_call_status)(profile, call_id)
    except Exception as exc:  # noqa: BLE001 - 补拉失败不打断观察
        logger.warning(
            "voice observer status refresh failed for call %s: %s", call_id, exc
        )
        return
    event = {
        "type": "elysia.voice.call.status",
        "data": {"call": _voice_call_status_data(status)},
    }
    await _group_send_observer(event)


async def _broadcast_projected(call_id: str, total: int) -> None:
    """广播 elysia.voice.projected 帧（累计投影数，前端「已投影 N 条」即时更新）。"""
    event = {
        "type": "elysia.voice.projected",
        "data": {"call_id": call_id, "projected_total": total},
    }
    await _group_send_observer(event)


async def _group_send_observer(event: dict) -> None:
    """组广播：捕获 ChannelFull 记 warning，不阻塞观察线程。"""
    layer = get_channel_layer()
    if layer is None:  # pragma: no cover - 测试环境无 layer
        return
    try:
        await layer.group_send(OBSERVER_GROUP, event)
    except ChannelFull:
        logger.warning("elysia_voice group full; event dropped")
    except Exception:  # noqa: BLE001
        logger.exception("elysia_voice group_send failed")


__all__ = [
    "OBSERVER_GROUP",
    "OBSERVER_SUBPROTOCOL",
    "ensure_observing",
    "stop_observing",
]
