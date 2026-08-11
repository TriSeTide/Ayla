"""emoji 模型契约测试（8.1 清单：EmojiPack/EmojiItem 约束、唯一）。"""
import pytest
from django.db import IntegrityError

from apps.media.models import MediaObject
from apps.emoji.models import EmojiItem, EmojiPack


@pytest.mark.django_db
class TestEmojiModels:
    def _mk_media(self, user, media_id="em-media-1", kind="emoji"):
        return MediaObject.objects.create(
            media_id=media_id, owner=user, kind=kind, status=MediaObject.STATUS_READY
        )

    def test_pack_item_unique_pack_media(self, user_factory):
        owner = user_factory(username="em_u1")
        media = self._mk_media(owner)
        pack = EmojiPack.objects.create(owner=owner, name="我的", is_system=False)
        EmojiItem.objects.create(pack=pack, media=media, tag="")
        with pytest.raises(IntegrityError):
            EmojiItem.objects.create(pack=pack, media=media, tag="")

    def test_system_pack_no_owner(self, user_factory):
        pack = EmojiPack.objects.create(owner=None, name="系统包", is_system=True)
        assert pack.owner is None
        assert pack.is_system is True
