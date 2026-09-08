"""
S5 聚合搜索 —— 只读聚合层（无模型、无迁移）。

设计边界（工程约束，AGENTS.md §2.2 / §3）：
- **只读聚合**：不建 FTS、不引搜索引擎、不建索引；六类查询各自复用现有 queryset 与
  输出 serializer，`q` 用 `icontains` 做内存外的数据库 LIKE 过滤（数据量小，天然满足）。
- **可见性过滤**：post/live/voice/game 走 `apps/common/visibility.py` 的 `visible_queryset`，
  与列表接口同语义（public 全登录 / friends 好友 / group 群员）；user/group 不涉及可见性
  （user 为公开资料，group 无 visibility 字段，见 `search_groups` 的取舍注释）。
- **有界结果 + total**：旧调用保持每组截断；显式游标模式由 pagination.py 在 SQL 中
  应用时间/主键 keyset 与 limit+1。total 始终是当前完整可见匹配数，不是剩余页数。
- **超时预算 2s 是设计目标，非本期硬编码实现**：采用同步聚合 + 每类独立 LIMIT 截断
  （数据量小、单次查询可控），不引入线程池硬超时/协程并发，避免过度设计；若未来数据量
  增长需在调用方加超时预算与并发降级。
"""
from django.contrib.auth import get_user_model
from django.db.models import Count, Exists, OuterRef, Q

from apps.accounts.serializers import UserPublicSerializer
from apps.boardgame.models import GameRoom
from apps.boardgame.serializers import GameRoomSerializer
from apps.chat.models import Conversation, ConversationMember
from apps.common.visibility import visible_queryset
from apps.live.models import LiveChannel
from apps.live.serializers import LiveChannelSerializer
from apps.posts.models import Post
from apps.posts.serializers import PostSerializer
from apps.voice.models import VoiceChannel, VoiceChannelMember
from apps.voice.serializers import VoiceChannelSerializer

from .pagination import SearchPageOptions, search_page

User = get_user_model()

# 合法类型子集（types 参数白名单；非法值忽略）
TYPE_USERS = "user"
TYPE_GROUPS = "group"
TYPE_POSTS = "post"
TYPE_LIVES = "live"
TYPE_VOICES = "voice"
TYPE_GAMES = "game"
VALID_TYPES = (TYPE_USERS, TYPE_GROUPS, TYPE_POSTS, TYPE_LIVES, TYPE_VOICES, TYPE_GAMES)

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


def _rows(base, q, kind, limit, request, page, time_field="created_at"):
    if page is not None:
        return search_page(
            base, request, query=q, kind=kind, time_field=time_field, options=page,
        )
    return base.order_by(f"-{time_field}", "-pk")[:limit], {"total": base.count()}


def search_users(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """用户：username/nickname icontains，UserPublicSerializer 输出，无可见性过滤。"""
    base = User.objects.filter(Q(username__icontains=q) | Q(nickname__icontains=q))
    rows, metadata = _rows(base, q, TYPE_USERS, limit, request, page, "date_joined")
    items = UserPublicSerializer(
        rows, many=True, context={"request": request}
    ).data
    return {"items": items, **metadata}


def search_groups(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """群聊：title icontains，轻量 dict 输出。

    已知取舍：Conversation 没有 visibility 字段（S2 已登记），入群申请对任意登录用户
    开放，故群搜索 = 所有群聊（title 匹配），不做可见性过滤；也不复用
    ConversationListSerializer（避免未读数等重查询）。
    join_policy（public/application）随条目输出，供前端区分"直接加入/申请制"弹窗。
    avatar 复用已有群头像媒体地址；未设置时为空串，不要求调用者已经入群。
    """
    base = Conversation.objects.filter(type="group").filter(title__icontains=q).annotate(
        _search_is_member=Exists(ConversationMember.objects.filter(
            conversation_id=OuterRef("pk"), user=request.user,
        )),
        _search_member_count=Count("members", distinct=True),
    )
    rows, metadata = _rows(base, q, TYPE_GROUPS, limit, request, page)
    items = [
        {
            "id": str(c.id),
            "type": c.type,
            "title": c.title,
            "avatar": c.avatar,
            "is_member": c._search_is_member,
            "member_count": c._search_member_count,
            "join_policy": c.join_policy,
            "created_at": c.created_at.isoformat(),
        }
        for c in rows
    ]
    return {"items": items, **metadata}


def search_posts(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """帖子：可见性过滤 + title/body icontains；select_related/prefetch 减少 N+1。"""
    base = (
        visible_queryset(Post, request.user)
        .filter(Q(title__icontains=q) | Q(body__icontains=q))
        .select_related("owner", "group")
        .prefetch_related("images__media")
    )
    rows, metadata = _rows(base, q, TYPE_POSTS, limit, request, page)
    items = PostSerializer(
        rows, many=True, context={"request": request}
    ).data
    return {"items": items, **metadata}


def search_lives(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """直播间：可见性过滤 + title icontains。"""
    base = (
        visible_queryset(LiveChannel, request.user)
        .filter(title__icontains=q)
        .select_related("group")
    )
    rows, metadata = _rows(base, q, TYPE_LIVES, limit, request, page)
    items = LiveChannelSerializer(
        rows, many=True, context={"request": request}
    ).data
    return {"items": items, **metadata}


def search_games(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """桌游室：可见性过滤 + name icontains；select_related/prefetch 减少 N+1。"""
    base = (
        visible_queryset(GameRoom, request.user)
        .filter(name__icontains=q)
        .select_related("owner", "group")
        .prefetch_related("members__user")
    )
    rows, metadata = _rows(base, q, TYPE_GAMES, limit, request, page)
    items = GameRoomSerializer(
        rows, many=True, context={"request": request}
    ).data
    return {"items": items, **metadata}


def search_voices(q: str, limit: int, request, page: SearchPageOptions | None = None) -> dict:
    """Visible voice rooms with current membership counts and requester presence.

    Counts use the same VoiceChannelMember authority as the voice directory;
    no LiveKit token is issued and membership is never inferred from a preview.
    """
    base = (
        visible_queryset(VoiceChannel, request.user)
        .filter(name__icontains=q)
        .select_related("owner", "group")
        .annotate(
            member_count=Count("members", distinct=True),
            _search_mine=Exists(VoiceChannelMember.objects.filter(
                channel_id=OuterRef("pk"), user=request.user,
            )),
        )
    )
    rows, metadata = _rows(base, q, TYPE_VOICES, limit, request, page)
    items = []
    for channel in rows:
        item = VoiceChannelSerializer(channel, context={"request": request}).data
        item["mine"] = channel._search_mine
        items.append(item)
    return {"items": items, **metadata}
