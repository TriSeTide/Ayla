"""
桌游领域服务（S4，开发文档 §1.4）—— 房间创建、join/leave（幂等）、可见性默认。

- 可见性默认复用 S1 语义：group 非空且未显式指定 → group 可见，否则 public；
  visibility=group 必须带 group（工程约束，§1.1）；
- join 幂等：同 (room, user) 已有成员直接返回（DB unique_together 兜底 + services 查重）；
- seat 占位分配：join 时按当前成员数顺序给号（玩法引擎后续接管，本期不保证并发唯一）。
"""
from apps.common.visibility import Visibility

from .models import GameRoom, GameRoomMember

# 占位游戏类型（玩法本体后续实现）
DEFAULT_GAME_TYPE = "boardgame"


def _resolve_visibility(group, visibility) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。"""
    if visibility in (None, ""):
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    if visibility == Visibility.GROUP and group is None:
        raise ValueError("群成员可见必须指定群")
    return visibility


def create_room(user, name: str, group=None, visibility=None, game_type=None) -> GameRoom:
    """创建桌游室。game_type 本期固定占位（默认 boardgame），玩法后续实现。"""
    name = (name or "").strip()
    if not name:
        raise ValueError("房间名不能为空")
    if group is not None and str(getattr(group, "type", "")) != "group":
        raise ValueError("group 必须是群聊会话")
    visibility = _resolve_visibility(group, visibility)
    return GameRoom.objects.create(
        owner=user,
        name=name,
        group=group,
        visibility=visibility,
        game_type=game_type or DEFAULT_GAME_TYPE,
    )


def join_room(room: GameRoom, user) -> tuple[GameRoomMember, bool]:
    """加入房间（幂等）：已是成员返回 (member, False)；新建返回 (member, True)。"""
    member = GameRoomMember.objects.filter(room=room, user=user).first()
    if member is not None:
        return member, False
    seat = GameRoomMember.objects.filter(room=room).count()
    member = GameRoomMember.objects.create(room=room, user=user, seat=seat)
    return member, True


def leave_room(room: GameRoom, user) -> bool:
    """离开房间：删除成员；非成员返回 False。"""
    member = GameRoomMember.objects.filter(room=room, user=user).first()
    if member is None:
        return False
    member.delete()
    return True
