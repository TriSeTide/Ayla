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


def create_comment(post: Post, author, body: str, reply_to=None, media_id: str | None = None) -> Comment:
    """创建评论（body 非空已在 serializer 校验，此处兜底；media_id 已由 serializer 校验）。"""
    body = (body or "").strip()
    if not body:
        raise ValueError("评论内容不能为空")
    return Comment.objects.create(
        post=post, author=author, body=body, reply_to=reply_to, media_id=media_id or None
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
