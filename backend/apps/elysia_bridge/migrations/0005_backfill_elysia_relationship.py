"""存量补齐：所有既有账号默认是爱莉的好友，并默认有一条与她的私聊会话。

背景
====

用户（TriSeTide）2026-11-11 定的规则一/二：不引入任何"爱莉专属入口"，把爱莉
当作普通 user —— 新注册账号在 `RegisterView` 里经
`elysia_bridge.services.ensure_elysia_relationship` 自动成为她的好友并建好私聊；
本迁移负责**存量**：迁移前已有的账号（当时 12 个）一条 Friendship 都没有，
在好友列表里找不到她、会话列表里也没有她。

数据影响面（仅两张表，且都是可安全重复的关系行）：

- `friendships`：user→爱莉、爱莉→user 各一条，`status='accepted'`
  （与 `FriendRequestActionView.accept` 的写入形状一致：双向各一条）；
- `conversations` + `conversation_members`：一条 PRIVATE 会话 + 两条成员记录
  （`get_or_create_conversation` 的形状：a=owner/member，b=member）。

为什么内联等价逻辑而不直接调 `chat.services.get_or_create_conversation`
==========================================================

数据迁移必须绑定**历史模型**（`apps.get_model`），而 `chat.services` 模块
import 的是当前 `apps.chat.models`。在迁移里调用它，等于让旧迁移依赖未来版本
的服务层实现：将来服务层改签名/改私聊唯一性规则，这条历史迁移会突然失败或
写出与当期不同的数据。这里逐字内联同样的逻辑（查找"同时含两人的 PRIVATE
会话"→ 没有才建会话 + 两条成员），与 `get_or_create_conversation` 保持同语义。
注册路径仍然只用那一个 helper，不复制第二份运行时实现。

幂等（硬要求）
==============

- Friendship：`update_or_create` + DB 层 `unique_together(user, friend)` 兜底，
  重复执行只更新 status，不产生重复行（即便存在旧的 pending 行也会被收敛）；
- 会话：先按"同时含两人的 PRIVATE 会话"查找，找到就不建；
- 成员：`get_or_create` + `unique_together(conversation, user)`。

因此**重复执行完全安全**，可在任意时刻手工重跑补齐。

可回退性（为什么反向是 no-op）
==============================

本迁移**不提供删除型反向**，反向为 `RunPython.noop`，理由：

1. 本迁移写入的行与用户自己正常加的"爱莉好友"、自己点的"和爱莉的私聊"在表里
   完全同形（没有 provenance 列可以区分谁写的），反向删除无法只命中"本迁移创建
   的那部分"；
2. 会话一旦被删除，`conversation_members`（CASCADE）与 `Message`
   （该迁移链上 messages.conversation 为 CASCADE）会一并消失 —— 删会话等于
   不可逆地销毁聊天历史，这远超"回退一次数据补齐"的风险范围；
3. 规则一/二表达的是产品期望的稳态关系，不是临时数据。真正想撤掉时应该是
   一次显式的、带审计与备份的业务操作，而不是 schema 回退的副作用。

回退的实际效果：schema 回到 0004，关系行保留；再前进一次因为幂等不会重复插入。
综上，no-op 反向是"零隐藏数据破坏"的选择。
"""
from __future__ import annotations

import logging

from django.db import migrations

logger = logging.getLogger(__name__)


def _ensure_relationship(
    Friendship, Conversation, ConversationMember, user, elysia
) -> bool:
    """给单个 user 补齐：双向 accepted 好友 + 一条与爱莉的 PRIVATE 会话。"""
    for owner_id, friend_id in ((user.pk, elysia.pk), (elysia.pk, user.pk)):
        Friendship.objects.update_or_create(
            user_id=owner_id,
            friend_id=friend_id,
            defaults={"status": "accepted"},
        )

    conv = (
        Conversation.objects.filter(type="private")
        .filter(members__user_id=user.pk)
        .filter(members__user_id=elysia.pk)
        .distinct()
        .first()
    )
    if conv is not None:
        return False

    conv = Conversation.objects.create(type="private", title="", owner_id=user.pk)
    ConversationMember.objects.get_or_create(
        conversation=conv, user_id=user.pk, defaults={"role": "owner"}
    )
    ConversationMember.objects.get_or_create(
        conversation=conv, user_id=elysia.pk, defaults={"role": "member"}
    )
    return True


def forward(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    Friendship = apps.get_model("accounts", "Friendship")
    ElysiaProfile = apps.get_model("elysia_bridge", "ElysiaProfile")
    Conversation = apps.get_model("chat", "Conversation")
    ConversationMember = apps.get_model("chat", "ConversationMember")

    profile = (
        ElysiaProfile.objects.filter(enabled=True, user__is_active=True)
        .order_by("id")
        .first()
    )
    if profile is None:
        # 与 ensure_elysia_relationship 同样的降级：爱莉还没建立时静默跳过，
        # 迁移不能因此失败（新部署/测试库常见）。
        logger.warning(
            "backfill elysia relationship skipped: no enabled elysia profile"
        )
        return

    elysia = User.objects.filter(pk=profile.user_id).first()
    if elysia is None:
        logger.warning(
            "backfill elysia relationship skipped: profile %s has no user", profile.pk
        )
        return

    users = User.objects.filter(is_active=True).exclude(pk=elysia.pk).order_by("date_joined")
    total = 0
    created_conversations = 0
    for user in users.iterator():
        if _ensure_relationship(
            Friendship, Conversation, ConversationMember, user, elysia
        ):
            created_conversations += 1
        total += 1

    logger.info(
        "backfill elysia relationship: %s user(s) ensured, %s new conversation(s)",
        total,
        created_conversations,
    )


class Migration(migrations.Migration):
    dependencies = [
        ("chat", "0013_message_share_payload_alter_message_type"),
        ("elysia_bridge", "0004_converge_profile_and_inbound_outbox"),
    ]

    operations = [
        # 反向 no-op：理由见模块 docstring「可回退性」。正向幂等，可安全重跑。
        migrations.RunPython(forward, migrations.RunPython.noop),
    ]
