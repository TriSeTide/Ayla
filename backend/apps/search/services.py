"""
S5 聚合搜索 —— 只读聚合层（无模型、无迁移）。

设计边界（工程约束，AGENTS.md §2.2 / §3）：
- **只读聚合**：不建 FTS、不引搜索引擎、不建索引；五类查询各自复用现有 queryset 与
  输出 serializer，`q` 用 `icontains` 做内存外的数据库 LIKE 过滤（数据量小，天然满足）。
- **可见性过滤**：post/live/game 走 `apps/common/visibility.py` 的 `visible_queryset`，
  与列表接口同语义（public 全登录 / friends 好友 / group 群员）；user/group 不涉及可见性
  （user 为公开资料，group 无 visibility 字段，见 `search_groups` 的取舍注释）。
- **每组截断 + total**：每类先 `order_by` 再 `[:limit]` 截断，`total` 单独 `count()`，
  二者分离保证"截断前匹配总数"准确；`limit` 默认 10、上限 50、下限 1。
- **超时预算 2s 是设计目标，非本期硬编码实现**：采用同步聚合 + 每类独立 LIMIT 截断
  （数据量小、单次查询可控），不引入线程池硬超时/协程并发，避免过度设计；若未来数据量
  增长需在调用方加超时预算与并发降级。
"""
from django.contrib.auth import get_user_model
from django.db.models import Q

from apps.accounts.serializers import UserPublicSerializer
from apps.boardgame.models import GameRoom
from apps.boardgame.serializers import GameRoomSerializer
from apps.chat.models import Conversation
from apps.common.visibility import visible_queryset
from apps.live.models import LiveChannel
from apps.live.serializers import LiveChannelSerializer
from apps.posts.models import Post
from apps.posts.serializers import PostSerializer

User = get_user_model()

# 合法类型子集（types 参数白名单；非法值忽略）
TYPE_USERS = "user"
TYPE_GROUPS = "group"
TYPE_POSTS = "post"
TYPE_LIVES = "live"
TYPE_GAMES = "game"
VALID_TYPES = (TYPE_USERS, TYPE_GROUPS, TYPE_POSTS, TYPE_LIVES, TYPE_GAMES)

# limit 参数边界
DEFAULT_LIMIT = 10
MAX_LIMIT = 50
MIN_LIMIT = 1


def parse_types(raw: str | None) -> list[str]:
    """解析 `types` 参数：逗号分隔白名单，非法值忽略、去重且保持既定顺序。"""
    if not raw:
        return list(VALID_TYPES)
    seen: list[str] = []
    for item in raw.split(","):
        item = item.strip()
        if item in VALID_TYPES and item not in seen:
            seen.append(item)
    return seen


def parse_limit(raw: str | None) -> int:
    """解析 `limit` 参数：缺省 10，夹紧到 [1, 50]；非整数视为缺省。"""
    if raw is None:
        return DEFAULT_LIMIT
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_LIMIT
    return max(MIN_LIMIT, min(value, MAX_LIMIT))


def search_users(q: str, limit: int, request) -> dict:
    """用户：username/nickname icontains，UserPublicSerializer 输出，无可见性过滤。"""
    base = User.objects.filter(Q(username__icontains=q) | Q(nickname__icontains=q))
    total = base.count()
    items = UserPublicSerializer(
        base.order_by("-date_joined")[:limit], many=True, context={"request": request}
    ).data
    return {"items": items, "total": total}


def search_groups(q: str, limit: int) -> dict:
    """群聊：title icontains，轻量 dict 输出。

    已知取舍：Conversation 没有 visibility 字段（S2 已登记），入群申请对任意登录用户
    开放，故群搜索 = 所有群聊（title 匹配），不做可见性过滤；也不复用
    ConversationListSerializer（避免未读数等重查询）。
    """
    base = Conversation.objects.filter(type="group").filter(title__icontains=q)
    total = base.count()
    items = [
        {
            "id": str(c.id),
            "type": c.type,
            "title": c.title,
            "created_at": c.created_at.isoformat(),
        }
        for c in base.order_by("-created_at")[:limit]
    ]
    return {"items": items, "total": total}


def search_posts(q: str, limit: int, request) -> dict:
    """帖子：可见性过滤 + title/body icontains；select_related/prefetch 减少 N+1。"""
    base = (
        visible_queryset(Post, request.user)
        .filter(Q(title__icontains=q) | Q(body__icontains=q))
        .select_related("owner", "group")
        .prefetch_related("images__media")
    )
    total = base.count()
    items = PostSerializer(
        base.order_by("-created_at")[:limit], many=True, context={"request": request}
    ).data
    return {"items": items, "total": total}


def search_lives(q: str, limit: int, request) -> dict:
    """直播间：可见性过滤 + title icontains。"""
    base = (
        visible_queryset(LiveChannel, request.user)
        .filter(title__icontains=q)
        .select_related("group")
    )
    total = base.count()
    items = LiveChannelSerializer(
        base.order_by("-created_at")[:limit], many=True, context={"request": request}
    ).data
    return {"items": items, "total": total}


def search_games(q: str, limit: int, request) -> dict:
    """桌游室：可见性过滤 + name icontains；select_related/prefetch 减少 N+1。"""
    base = (
        visible_queryset(GameRoom, request.user)
        .filter(name__icontains=q)
        .select_related("owner", "group")
        .prefetch_related("members__user")
    )
    total = base.count()
    items = GameRoomSerializer(
        base.order_by("-created_at")[:limit], many=True, context={"request": request}
    ).data
    return {"items": items, "total": total}
