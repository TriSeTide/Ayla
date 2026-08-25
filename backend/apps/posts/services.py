"""
帖子领域服务（S3，开发文档 §1.3）—— 帖子/评论创建、可见性默认、游标编解码。

设计要点：
- 可见性默认复用 S1 语义：group 非空且未显式指定 → group 可见，否则 public；
  visibility=group 必须带 group（工程约束，§1.1）；
- 游标分页：created_at desc + id desc 稳定排序，游标 = base64url(created_at.isoformat()|id)，
  "created_at < 游标时间 OR (created_at = 游标时间 AND id < 游标id)" 翻页，天然去重；
- 图片引用在 serializer 层完成合法性校验（media 存在/READY/image/访问权），
  service 只做落库（media_id → MediaObject 兜底防御，未命中跳过）。
"""
import base64
from datetime import datetime

from django.db import transaction

from apps.common.visibility import Visibility

from .models import Comment, Post, PostImage

# 游标分隔符（created_at.isoformat() 不含此字符）
_CURSOR_SEP = "|"
# 仅公开帖加入全局信息流组；好友/群组帖子必须走定向组，避免泄漏。
POST_FEED_GROUP = "chat_posts_feed"


def _resolve_visibility(group, visibility, allowed_group_ids) -> str:
    """S1 可见性默认：group 非空且未显式指定 → group 可见；否则 public。"""
    if visibility in (None, ""):
        return Visibility.GROUP if group is not None else Visibility.PUBLIC
    if visibility == Visibility.GROUP and group is None and not allowed_group_ids:
        raise ValueError("群成员可见必须指定群或 allowed_group_ids")
    return visibility


@transaction.atomic
def create_post(author, title: str, body: str, images=None, group=None, visibility=None, allowed_group_ids=None) -> Post:
    """创建帖子 + 配图（images 为 media_id 字符串列表，已由 serializer 校验）。"""
    title = (title or "").strip()
    body = (body or "").strip()
    if not body:
        raise ValueError("正文不能为空")
    if group is not None and str(getattr(group, "type", "")) != "group":
        raise ValueError("group 必须是群聊会话")
    visibility = _resolve_visibility(group, visibility, allowed_group_ids)

    post = Post.objects.create(
        owner=author, title=title, body=body, group=group, visibility=visibility
    )
    if allowed_group_ids is not None:
        from apps.common.visibility import set_allowed_groups
        set_allowed_groups(post, allowed_group_ids)
    for order, media_id in enumerate(images or []):
        media = _resolve_media(media_id)
        if media is None:
            # serializer 已校验，此处仅兜底防御，不静默伪造（跳过缺失引用）
            continue
        PostImage.objects.create(post=post, media=media, order=order)
    return post


def _resolve_media(media_id: str):
    from apps.media.models import MediaObject

    return MediaObject.objects.filter(media_id=media_id).first()


def create_comment(
    post: Post,
    author,
    body: str,
    reply_to=None,
    media_id: str | None = None,
    images: list[str] | None = None,
) -> Comment:
    """创建评论（图文同发：images 为 media_id 列表；body 与图片至少其一）。

    兼容旧签名：仅传 media_id 时等价 images=[media_id]。有图片时允许 body 为空。
    """
    body = (body or "").strip()
    ids = list(dict.fromkeys(images or []))
    if not ids and media_id:
        ids = [media_id]
    if not body and not ids:
        raise ValueError("评论内容不能为空")
    return Comment.objects.create(
        post=post, author=author, body=body, reply_to=reply_to,
        media_id=(ids[0] if ids else None),
        images=ids,
    )


# ---------- 游标编解码 ----------

def _b64encode(raw: str) -> str:
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")


def _b64decode(data: str) -> str:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad).decode("utf-8")


def encode_cursor(post: Post) -> str:
    """把帖子位置编码为游标（created_at.isoformat() + 分隔符 + id）。"""
    return _b64encode(f"{post.created_at.isoformat()}{_CURSOR_SEP}{post.id}")


def decode_cursor(cursor: str) -> tuple[datetime, int]:
    """解码游标 → (created_at, id)；非法游标抛 ValueError（视图返回 400）。"""
    try:
        raw = _b64decode(cursor)
        dt_s, _, id_s = raw.rpartition(_CURSOR_SEP)
        if not dt_s or not id_s:
            raise ValueError
        dt = datetime.fromisoformat(dt_s)
        pid = int(id_s)
    except (ValueError, TypeError):
        raise ValueError("cursor 无效")
    return dt, pid


# ---------- 帖子实时推送 ----------

def broadcast_post_created_to_group(post, group):
    """帖子创建推送给群成员（通过会话组 chat_conv_{group.id}）。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    try:
        event = {
            "type": "post.created",
            "post": {
                "id": str(post.id),
                "title": post.title,
                "body": post.body[:200],  # 截断避免过大
                "owner_id": str(post.owner_id),
                "group_id": str(post.group_id) if post.group_id else None,
                "visibility": post.visibility,
                "created_at": post.created_at.isoformat(),
            },
        }
        async_to_sync(layer.group_send)(f"chat_conv_{group.id}", event)
    except ChannelFull:
        logger.warning(
            "Channel layer full when broadcasting post.created to group %s", group.id
        )
    except Exception:
        logger.exception("Failed to broadcast post.created to group %s", group.id)


def broadcast_post_created_to_feed(post):
    """仅将公开帖推送到全局信息流组。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    if post.visibility != "public":
        return
    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return
    event = {
        "type": "post.created",
        "post": {
            "id": str(post.id),
            "title": post.title,
            "body": post.body[:200],
            "owner_id": str(post.owner_id),
            "group_id": str(post.group_id) if post.group_id else None,
            "visibility": post.visibility,
            "created_at": post.created_at.isoformat(),
        },
    }
    try:
        async_to_sync(layer.group_send)(POST_FEED_GROUP, event)
    except ChannelFull:
        logger.warning("Channel layer full when broadcasting public post %s", post.id)
    except Exception:
        logger.exception("Failed to broadcast public post %s", post.id)


def broadcast_post_created_to_user(post, user):
    """帖子创建推送给创建者本人。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    try:
        event = {
            "type": "post.created",
            "post": {
                "id": str(post.id),
                "title": post.title,
                "body": post.body[:200],
                "owner_id": str(post.owner_id),
                "group_id": str(post.group_id) if post.group_id else None,
                "visibility": post.visibility,
                "created_at": post.created_at.isoformat(),
            },
        }
        async_to_sync(layer.group_send)(f"chat_user_{user.id}", event)
    except ChannelFull:
        logger.warning(
            "Channel layer full when broadcasting post.created to user %s", user.id
        )
    except Exception:
        logger.exception("Failed to broadcast post.created to user %s", user.id)


def broadcast_post_deleted(post_id, group_id=None, owner_id=None, allowed_group_ids=None, visibility=None):
    """帖子删除推送（需要在删除前保存必要信息）。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    event = {
        "type": "post.deleted",
        "post_id": str(post_id),
    }

    try:
        if group_id:
            async_to_sync(layer.group_send)(f"chat_conv_{group_id}", event)
        if owner_id:
            async_to_sync(layer.group_send)(f"chat_user_{owner_id}", event)
        if allowed_group_ids:
            for gid in allowed_group_ids:
                async_to_sync(layer.group_send)(f"chat_conv_{gid}", event)
        if visibility == "public":
            async_to_sync(layer.group_send)(POST_FEED_GROUP, event)
    except ChannelFull:
        logger.warning("Channel layer full when broadcasting post.deleted %s", post_id)
    except Exception:
        logger.exception("Failed to broadcast post.deleted %s", post_id)


def broadcast_post_updated(post) -> None:
    """帖子被编辑后广播（标题/正文/可见性变更）。

    分发范围对齐 post.deleted：群归属 + 白名单群 + 公开信息流 + 作者本人。
    前端收到后以权限 REST 详情对账（不可见 403 → 忽略），轮播「最新帖」据此实时刷新。
    """
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    event = {
        "type": "post.updated",
        "post": {
            "id": str(post.id),
            "title": post.title,
            "body": post.body[:200],
            "owner_id": str(post.owner_id),
            "group_id": str(post.group_id) if post.group_id else None,
            "visibility": post.visibility,
            "created_at": post.created_at.isoformat(),
        },
    }

    targets = []
    if post.group_id:
        targets.append(f"chat_conv_{post.group_id}")
    targets.extend(
        f"chat_conv_{gid}" for gid in post.allowed_groups.values_list("id", flat=True)
    )
    if post.visibility == "public":
        targets.append(POST_FEED_GROUP)
    targets.append(f"chat_user_{post.owner_id}")

    for target in targets:
        try:
            async_to_sync(layer.group_send)(target, event)
        except ChannelFull:
            logger.warning("Channel layer full when broadcasting post.updated %s", post.id)
        except Exception:
            logger.exception("Failed to broadcast post.updated %s", post.id)


# ---------- 评论实时推送 ----------

def _comment_audience(post) -> list[str]:
    """评论事件的分发范围，对齐帖子可见性（避免向无权用户泄漏，与 post.created 同纪律）。

    返回频道组名列表：
    - public → 全局信息流组（所有在线用户）；
    - group / allowed_groups → 对应会话组 chat_conv_{gid}；
    - friends → 帖主本人的用户组（作者必然能看）。
    """
    from apps.common.visibility import Visibility

    groups = []
    if post.visibility == Visibility.PUBLIC:
        groups.append(POST_FEED_GROUP)
    if post.group_id:
        groups.append(f"chat_conv_{post.group_id}")
    # 多群可见（allowed_groups 与主 group 可能不同）
    if post.pk:
        groups.extend(
            f"chat_conv_{gid}" for gid in post.allowed_groups.values_list("id", flat=True)
        )
    if post.owner_id:
        groups.append(f"chat_user_{post.owner_id}")
    return list(dict.fromkeys(groups))


def broadcast_comment_created(post, serialized_comment, comment_count):
    """评论创建推送：向能看见该帖子的用户广播完整评论，前端可乐观插入 + 更新计数。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    event = {
        "type": "comment.created",
        "data": {
            "post_id": str(post.id),
            "comment": serialized_comment,
            "comment_count": comment_count,
        },
    }
    for group in _comment_audience(post):
        try:
            async_to_sync(layer.group_send)(group, event)
        except ChannelFull:
            logger.warning("Channel layer full when broadcasting comment.created to %s", group)
        except Exception:
            logger.exception("Failed to broadcast comment.created to %s", group)


def broadcast_comment_deleted(post, comment_id, comment_count):
    """评论删除推送：只携带 id，前端据此移除并更新计数。"""
    import logging
    from asgiref.sync import async_to_sync
    from channels.layers import get_channel_layer
    from channels.exceptions import ChannelFull

    logger = logging.getLogger(__name__)
    layer = get_channel_layer()
    if layer is None:
        return

    event = {
        "type": "comment.deleted",
        "data": {
            "post_id": str(post.id),
            "comment_id": comment_id,
            "comment_count": comment_count,
        },
    }
    for group in _comment_audience(post):
        try:
            async_to_sync(layer.group_send)(group, event)
        except ChannelFull:
            logger.warning("Channel layer full when broadcasting comment.deleted to %s", group)
        except Exception:
            logger.exception("Failed to broadcast comment.deleted to %s", group)
