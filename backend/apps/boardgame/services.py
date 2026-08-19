"""
桌游领域服务（S4，开发文档 §1.4）—— 房间创建、join/leave（幂等）、可见性默认。

- 可见性默认复用 S1 语义：group 非空且未显式指定 → group 可见，否则 public；
  visibility=group 的可见性由"归属群 group 或白名单 allowed_group_ids"提供
  （两者皆无时创建失败，工程约束，§1.1；Bug #10 放宽了原先"必须带 group"的一刀切校验）；
- join 幂等：同 (room, user) 已有成员直接返回（DB unique_together 兜底 + services 查重）；
- seat 占位分配：join 时按当前成员数顺序给号（玩法引擎后续接管，本期不保证并发唯一）。
"""
from apps.common.visibility import Visibility

from .models import GameRoom, GameRoomMember

# 占位游戏类型（玩法本体后续实现）
DEFAULT_GAME_TYPE = "boardgame"


def _resolve_visibility(group, visibility) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。

    visibility=group 且无归属群时不再拒绝（Bug #10）：可见性可由 allowed_group_ids
    白名单提供，是否真的选了群由 create_room 在 allowed_group_ids 为空时校验。
    """
    if visibility in (None, ""):
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    return visibility


def create_room(user, name: str, group=None, visibility=None, game_type=None, allowed_group_ids=None) -> GameRoom:
    """创建桌游室。game_type 本期固定占位（默认 boardgame），玩法后续实现。

    visibility=group 时可见性来源：group 归属（单个）或 allowed_group_ids 白名单（多个）。
    两者皆无（group 为空且 allowed_group_ids 为 None/空数组）→ ValueError，
    由视图层转 400"至少选择一个群"（Bug #10 校验后置）。
    """
    name = (name or "").strip()
    if not name:
        raise ValueError("房间名不能为空")
    if group is not None and str(getattr(group, "type", "")) != "group":
        raise ValueError("group 必须是群聊会话")
    visibility = _resolve_visibility(group, visibility)
    if visibility == Visibility.GROUP and group is None and not allowed_group_ids:
        raise ValueError("群成员可见必须至少选择一个群")
    room = GameRoom.objects.create(
        owner=user,
        name=name,
        group=group,
        visibility=visibility,
        game_type=game_type or DEFAULT_GAME_TYPE,
    )
    if allowed_group_ids is not None:
        from apps.common.visibility import set_allowed_groups
        set_allowed_groups(room, allowed_group_ids)
    return room


def join_room(room: GameRoom, user) -> tuple[GameRoomMember, bool]:
    """加入房间（幂等）：已是成员返回 (member, False)；新建返回 (member, True)。"""
    member = GameRoomMember.objects.filter(room=room, user=user).first()
    if member is not None:
        return member, False
    seat = GameRoomMember.objects.filter(room=room).count()
    member = GameRoomMember.objects.create(room=room, user=user, seat=seat)
    return member, True


def transfer_room_owner(room: GameRoom, actor, target_user_id):
    """房主将房主身份转给当前成员。"""
    if room.owner_id != actor.id:
        raise PermissionError("仅房主可转让")
    target = GameRoomMember.objects.filter(room=room, user_id=target_user_id).first()
    if target is None:
        raise LookupError("目标成员不存在")
    room.owner_id = target.user_id
    room.save(update_fields=["owner"])
    return room


def kick_member(room: GameRoom, actor, user_id):
    if room.owner_id != actor.id:
        raise PermissionError("仅房主可踢人")
    if str(user_id) == str(actor.id):
        raise ValueError("不能踢自己")
    member = GameRoomMember.objects.filter(room=room, user_id=user_id).first()
    if member is None:
        raise LookupError("成员不存在")
    member.delete()


def leave_room(room: GameRoom, user) -> bool:
    """离开房间；房主必须先转让房主。"""
    if room.owner_id == user.id and GameRoomMember.objects.filter(room=room, user=user).exists():
        raise ValueError("房主请先转让房主后再离开")
    member = GameRoomMember.objects.filter(room=room, user=user).first()
    if member is None:
        return False
    member.delete()
    return True
