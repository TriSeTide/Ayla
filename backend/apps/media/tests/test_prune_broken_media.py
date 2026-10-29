"""prune_broken_media 的契约测试（清理无原件媒体对应的消息与记录）。

覆盖用户 2026-10-29 的裁决：
  Q1=B  混排消息只摘坏段、保留好段；全坏才整条删；
  Q2=B  MediaObject 记录一并删除；
  纯媒体消息 / 弹幕 / 语音房图片 整条删。

外加安全纪律：默认 dry-run 不动数据、备份文件必生成、单事务。
"""
import json
from pathlib import Path

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.chat.models import Conversation, Message
from apps.media import storage
from apps.media.models import MediaObject

PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c6300010000050001"
    "0d0a2db40000000049454e44ae426082"
)


def _hex(name):
    import hashlib

    return hashlib.md5(name.encode()).hexdigest()


def _mk(user, name, kind="image", alive=True):
    mid = _hex(name)
    store = storage.get_storage()
    m = MediaObject.objects.create(
        media_id=mid,
        owner=user,
        kind=kind,
        content_hash=f"h-{mid}",
        mime_type="image/png",
        size=len(PNG),
        storage_path=storage.original_key(kind, mid),
        status=MediaObject.STATUS_READY,
    )
    if alive:
        store.put(m.storage_path, PNG, "image/png")
    return m


def _conv(user):
    return Conversation.objects.create(type=Conversation.TYPE_PRIVATE, owner=user)


def _msg(conv, user, **kwargs):
    """建消息并自动补 seq（Message.seq 是会话内序号，非空约束）。"""
    from django.db.models import Max

    last = Message.objects.filter(conversation=conv).aggregate(m=Max("seq"))["m"] or 0
    return Message.objects.create(conversation=conv, sender=user, seq=last + 1, **kwargs)


@pytest.mark.django_db
class TestPruneBrokenMedia:
    def _prune(self, appply, tmp_path):
        args = []
        if appply:
            args.append("--apply")
        out = __import__("io").StringIO()
        call_command(
            "prune_broken_media", *args, "--backup-dir", str(tmp_path), stdout=out
        )
        return out.getvalue()

    def test_dry_run_keeps_data_but_writes_backup(self, user_factory, tmp_path):
        user = user_factory(username="pb1")
        conv = _conv(user)
        media = _mk(user, "pb-voice", kind="voice", alive=False)
        msg = _msg(conv, user, type="voice", media_id=media.media_id)
        text = self._prune(False, tmp_path)
        assert Message.objects.filter(id=msg.id).exists(), "dry-run 不能删数据"
        assert MediaObject.objects.filter(id=media.id).exists()
        backups = list(Path(tmp_path).glob("media-cleanup-backup-*.json"))
        assert len(backups) == 1
        data = json.loads(backups[0].read_text(encoding="utf-8"))
        assert len(data["messages_deleted"]) == 1
        assert "dry-run" in text

    def test_apply_deletes_plain_media_message(self, user_factory, tmp_path):
        user = user_factory(username="pb2")
        conv = _conv(user)
        media = _mk(user, "pb-voice2", kind="voice", alive=False)
        msg = _msg(conv, user, type="voice", media_id=media.media_id)
        self._prune(True, tmp_path)
        assert not Message.objects.filter(id=msg.id).exists()
        assert not MediaObject.objects.filter(id=media.id).exists()

    def test_mixed_keeps_good_segment(self, user_factory, tmp_path):
        """Q1=B：混排消息只摘坏段，好的那几段必须留着。"""
        user = user_factory(username="pb3")
        conv = _conv(user)
        bad = _mk(user, "pb-bad", alive=False)
        good = _mk(user, "pb-good", alive=True)
        msg = _msg(
            conv,
            user,
            type="mixed",
            segments=[
                {"type": "image", "media_id": bad.media_id},
                {"type": "image", "media_id": good.media_id},
            ],
        )
        self._prune(True, tmp_path)
        msg.refresh_from_db()
        assert [s["media_id"] for s in msg.segments] == [good.media_id]
        assert Message.objects.filter(id=msg.id).exists(), "还有好段就不能整条删"

    def test_mixed_all_bad_deletes_message(self, user_factory, tmp_path):
        user = user_factory(username="pb4")
        conv = _conv(user)
        bad = _mk(user, "pb-allbad", alive=False)
        msg = _msg(
            conv,
            user,
            type="mixed",
            segments=[{"type": "image", "media_id": bad.media_id}],
        )
        self._prune(True, tmp_path)
        assert not Message.objects.filter(id=msg.id).exists()

    def test_healthy_media_untouched(self, user_factory, tmp_path):
        user = user_factory(username="pb5")
        conv = _conv(user)
        good = _mk(user, "pb-healthy", alive=True)
        msg = _msg(conv, user, type="image", media_id=good.media_id)
        self._prune(True, tmp_path)
        assert Message.objects.filter(id=msg.id).exists()
        assert MediaObject.objects.filter(id=good.id).exists()
        assert storage.get_storage().exists(good.storage_path)

    def test_nothing_to_do(self, user_factory, tmp_path):
        user = user_factory(username="pb6")
        _mk(user, "pb-fine", alive=True)
        out = self._prune(True, tmp_path)
        assert "无事可做" in out
