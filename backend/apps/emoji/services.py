"""
表情包领域服务（M4-3，步骤文件 5.5 / 3.4）。

- 收藏/取消收藏（包 owner）；系统包校验；检索（基础 tag/名称匹配，不建 FTS）；
- 幂等：EmojiPack 个人包用 get_or_create；系统包用 get_or_create_system_pack（owner=None 按 is_system+name）；
- EmojiItem.unique(pack, media) 由 DB 硬约束，services 捕获后幂等返回。

主体性铁律（AGENTS.md §4.1 / FR-12）：
- 应用侧绝不生成/改写爱莉第一人称内容；爱莉表情只做渲染/投影（本服务不做 AI 决策）。
"""
import logging

from django.db import IntegrityError

from apps.media.models import MediaObject

from .models import EmojiItem, EmojiPack

logger = logging.getLogger(__name__)


def get_or_create_system_pack(name: str) -> EmojiPack:
    """系统包幂等：按 is_system=True, name 查找，不存在则建（owner=None）。"""
    pack = EmojiPack.objects.filter(is_system=True, name=name).first()
    if pack is not None:
        return pack
    return EmojiPack.objects.create(owner=None, name=name, is_system=True)


def create_personal_pack(user, name: str) -> EmojiPack:
    """建个人表情包（幂等：同名已有则返回既有）。"""
    return EmojiPack.objects.get_or_create(owner=user, name=name, is_system=False)[0]


def can_manage_pack(user, pack: EmojiPack) -> bool:
    """包 owner 或系统包管理员。"""
    if pack.is_system:
        return user.is_superuser
    return pack.owner_id == user.id


def can_view_pack(user, pack: EmojiPack) -> bool:
    """包 owner 或系统包（全员可见）。"""
    if pack.is_system:
        return True
    return pack.owner_id == user.id


def add_item(user, pack: EmojiPack, media: MediaObject, tag: str = "") -> EmojiItem:
    """收藏表情：media 必须 kind=emoji 且 ready，且调用方对其有访问权。

    返回 (item, created)；重复收藏由 DB unique 约束兜底幂等返回既有。
    """
    from apps.media.services import can_access_media

    if not can_manage_pack(user, pack):
        raise PermissionError("仅包 owner 可收藏")
    if media.kind != MediaObject.KIND_EMOJI:
        raise ValueError("media_type_mismatch")
    if media.status != MediaObject.STATUS_READY:
        raise ValueError("media_not_ready")
    if not can_access_media(user, media):
        raise PermissionError("无权访问该媒体")
    # 幂等：重复收藏返回既有 item（先查重，避免依赖 IntegrityError 污染外层事务）
    existing = EmojiItem.objects.filter(pack=pack, media=media).first()
    if existing is not None:
        return existing, False
    try:
        item = EmojiItem.objects.create(pack=pack, media=media, tag=tag or "")
        return item, True
    except IntegrityError:
        existing = EmojiItem.objects.filter(pack=pack, media=media).first()
        return existing, False


def remove_item(user, pack: EmojiPack, item: EmojiItem) -> None:
    """取消收藏（包 owner）。"""
    if not can_manage_pack(user, pack):
        raise PermissionError("仅包 owner 可取消收藏")
    if item.pack_id != pack.id:
        raise ValueError("item_not_in_pack")
    item.delete()


def search_emoji(user, keyword: str, limit: int = 50):
    """按 tag/名称检索表情。

    检索排序只影响可达性，不自动改变事实状态（AGENTS.md §5.3）；
    只返回用户可见的包（系统包 + 本人个人包）。
    """
    from django.db.models import Q

    keyword = (keyword or "").strip()
    packs = EmojiPack.objects.filter(
        Q(is_system=True) | Q(owner=user)
    ).prefetch_related("items__media")
    results = []
    for pack in packs:
        if not keyword:
            hits = list(pack.items.all())[:limit]
        else:
            hits = [
                item
                for item in pack.items.all()
                if keyword in item.tag or keyword in pack.name
            ][:limit]
        if hits:
            results.append({"pack": pack, "hits": hits})
    return results
