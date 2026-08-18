"""
Chat WebSocket Consumer —— 应用内实时聊天。

连接：`/ws/chat/?token=<jwt>`，JWT 握手方式复用 accounts 的 `_jwt_user_from_scope`。
协议（步骤文件第 6 节）：
- 连接成功后客户端发 `subscribe` 帧订阅会话组，服务端校验成员后 group_add，
  并回 `chat.subscribed` 基线（含会话当前最大 seq，供 last_message_seq 补发基线）；
- `resume` 帧：重连后带 last_message_seq，服务端补发 seq > last_message_seq 的消息，
  最后发 `history.sync` 表示补发完成；
- 广播处理器：message.new / message.recall / message.read / typing，按事件类型同名方法；
- 事件帧里的 sender_id 由前端过滤"自己发的 vs 别人发的"，服务端照发（不做回环过滤）。
"""
import json
import logging

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from django.contrib.auth import get_user_model

from apps.accounts.consumers import _jwt_user_from_scope

from .models import Conversation, Message
from .services import conversation_seq, user_can_access

logger = logging.getLogger(__name__)

User = get_user_model()


@database_sync_to_async
def _get_conversation(conv_id):
    try:
        return Conversation.objects.get(pk=int(conv_id))
    except (Conversation.DoesNotExist, ValueError, TypeError):
        return None


@database_sync_to_async
def _can_access(user, conv):
    return user_can_access(user, conv)


@database_sync_to_async
def _conv_seq(conv):
    return conversation_seq(conv)


@database_sync_to_async
def _messages_after(conv, last_seq, limit=200):
    """补发：seq > last_seq 的消息，按 seq 升序。"""
    return list(
        Message.objects.filter(conversation=conv, seq__gt=last_seq)
        .order_by("seq")[:limit]
    )


def _message_new_payload(msg: Message) -> dict:
    return {
        "type": "message.new",
        "data": {
            "conversation_id": str(msg.conversation_id),
            "message_id": str(msg.id),
            "sender_id": msg.sender_id,
            "content": msg.content,
            "type": msg.type,
            "media": msg.media_id,
            "reply_to": str(msg.reply_to_id) if msg.reply_to_id else None,
            "seq": msg.seq,
            "ts": msg.created_at.isoformat(),
        },
    }


class ChatConsumer(AsyncJsonWebsocketConsumer):
    async def connect(self):
        self.user = await database_sync_to_async(_jwt_user_from_scope)(self.scope)
        if self.user is None:
            await self.close(code=4401)  # 未认证
            return
        self.subscribed = set()  # 已订阅的会话组
        # 用户级组：接收与自己相关的推送（S2 群申请处理/新邀请等），
        # 申请人/被邀请人未必是会话成员，订阅不到 chat_conv_* 组。
        self.user_group = f"chat_user_{self.user.id}"
        await self.channel_layer.group_add(self.user_group, self.channel_name)
        await self.accept()

    async def disconnect(self, code):
        for conv_id in getattr(self, "subscribed", set()):
            await self.channel_layer.group_discard(
                f"chat_conv_{conv_id}", self.channel_name
            )
        if getattr(self, "user_group", None):
            await self.channel_layer.group_discard(
                self.user_group, self.channel_name
            )

    async def receive_json(self, content, **kwargs):
        msg_type = content.get("type")
        if msg_type == "ping":
            await self.send_json({"type": "pong", "ts": content.get("ts")})
        elif msg_type == "subscribe":
            await self._handle_subscribe(content)
        elif msg_type == "resume":
            await self._handle_resume(content)
        else:
            await self.send_json({"type": "error", "detail": f"unknown type {msg_type}"})

    # ---------- 订阅 ----------

    async def _handle_subscribe(self, content):
        conv_ids = content.get("conversation_ids") or []
        for conv_id in conv_ids:
            conv = await _get_conversation(conv_id)
            if conv is None or not await _can_access(self.user, conv):
                # 非成员：忽略（不 group_add），不能收到广播
                logger.info("subscribe ignored for non-member conv %s", conv_id)
                continue
            group = f"chat_conv_{conv.id}"
            await self.channel_layer.group_add(group, self.channel_name)
            self.subscribed.add(conv.id)
            # 回基线：当前会话最大 seq
            seq = await _conv_seq(conv)
            await self.send_json(
                {
                    "type": "chat.subscribed",
                    "data": {"conversation_id": str(conv.id), "last_seq": seq},
                }
            )

    async def _handle_resume(self, content):
        conv_id = content.get("conversation_id")
        last_seq = content.get("last_message_seq") or 0
        conv = await _get_conversation(conv_id)
        if conv is None or not await _can_access(self.user, conv):
            await self.send_json({"type": "error", "detail": "无权访问"})
            return
        group = f"chat_conv_{conv.id}"
        await self.channel_layer.group_add(group, self.channel_name)
        self.subscribed.add(conv.id)
        # 补发 seq > last_message_seq 的消息
        try:
            last_seq = int(last_seq)
        except (TypeError, ValueError):
            last_seq = 0
        msgs = await _messages_after(conv, last_seq)
        for msg in msgs:
            await self.send_json(_message_new_payload(msg))
        current = await _conv_seq(conv)
        await self.send_json(
            {
                "type": "history.sync",
                "data": {"conversation_id": str(conv.id), "last_seq": current},
            }
        )

    # ---------- 广播处理器（group_send 事件 → send_json） ----------

    async def chat_message_new(self, event):
        await self.send_json(
            {
                "type": "message.new",
                "data": {
                    "conversation_id": event["conversation_id"],
                    "message_id": event["message_id"],
                    "sender_id": event["sender_id"],
                    "content": event["content"],
                    "type": event["msg_type"],
                    "media": event["media"],
                    "reply_to": event["reply_to"],
                    "seq": event["seq"],
                    "ts": event["ts"],
                },
            }
        )

    async def chat_message_recall(self, event):
        await self.send_json(
            {
                "type": "message.recall",
                "data": {
                    "conversation_id": event["conversation_id"],
                    "message_id": event["message_id"],
                    "seq": event["seq"],
                },
            }
        )

    async def chat_message_read(self, event):
        await self.send_json(
            {
                "type": "message.read",
                "data": {
                    "conversation_id": event["conversation_id"],
                    "message_id": event["message_id"],
                    "user_id": event["user_id"],
                    "seq": event["seq"],
                },
            }
        )

    async def chat_typing(self, event):
        await self.send_json(
            {
                "type": "typing",
                "data": {
                    "conversation_id": event["conversation_id"],
                    "user_id": event["user_id"],
                    "is_typing": event["is_typing"],
                },
            }
        )

    async def elysia_reply(self, event):
        """爱莉回复投影（M4-4 桥接 + M4-5 语音转写投影，来源见 ``source``）。

        事件已按幂等键落库为应用内 Message；这里把「爱莉的这条回复」推给
        该 conversation 组的在线用户。sender_id 即爱莉 profile 绑定的应用内 user。
        应用侧只转发投影内容，绝不生成爱莉的第一人称文本（AGENTS.md §4.1）。
        ``source`` 区分投影来源：chat（M4-4 聊天投影）与 voice_call（M4-5 语音
        转写投影，source 缺失时默认 chat，保持 M4-4 老事件兼容）。
        """
        await self.send_json(
            {
                "type": "elysia.reply",
                "data": {
                    "conversation_id": event["conversation_id"],
                    "message_id": event["message_id"],
                    "sender_id": event["sender_id"],
                    "content": event["content"],
                    "type": event["msg_type"],
                    "seq": event["seq"],
                    "event_id": event["event_id"],
                    "ts": event["ts"],
                    "source": event.get("source", "chat"),
                },
            }
        )

    # ---------- 用户级推送（S2：群申请处理 / 新邀请） ----------

    async def group_request_resolved(self, event):
        """申请被 owner/admin 处理后推给申请人。"""
        await self.send_json(
            {
                "type": "group.request.resolved",
                "data": {
                    "request_id": event["request_id"],
                    "conversation_id": event["conversation_id"],
                    "conversation_title": event["conversation_title"],
                    "status": event["status"],
                    "handled_by_id": event["handled_by_id"],
                    "handled_at": event["handled_at"],
                },
            }
        )

    async def group_request_new(self, event):
        await self.send_json({
            "type": "group.request.new",
            "data": {
                "request_id": event["request_id"],
                "conversation_id": event["conversation_id"],
                "conversation_title": event["conversation_title"],
                "applicant_id": event["applicant_id"],
                "applicant_name": event["applicant_name"],
            },
        })

    async def group_member_left(self, event):
        await self.send_json({
            "type": "group.member.left",
            "data": {
                "conversation_id": event["conversation_id"],
                "conversation_title": event["conversation_title"],
                "member_id": event["member_id"],
                "member_name": event["member_name"],
            },
        })

    async def group_invite_new(self, event):
        """新入群邀请推给被邀请人。"""
        await self.send_json(
            {
                "type": "group.invite.new",
                "data": {
                    "invite_id": event["invite_id"],
                    "conversation_id": event["conversation_id"],
                    "conversation_title": event["conversation_title"],
                    "inviter_id": event["inviter_id"],
                    "inviter_name": event["inviter_name"],
                    "created_at": event["created_at"],
                },
            }
        )
