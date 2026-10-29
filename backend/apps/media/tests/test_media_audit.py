"""媒体存储一致性审计的契约测试（media_audit 管理命令）。

覆盖：
1. 完全一致 ⇒ 退出码 0、输出 PASS；
2. 缺失（DB 有、对象无，且未完全过期）⇒ 退出码 1 且报出该 key；
3. **已完全过期的媒体对象缺失不算问题**（cleanup 的正常形态）；
4. 孤儿（对象有、DB 无引用）⇒ 退出码 1；--prune-orphans 默认只预览不删；
5. --prune-orphans --no-dry-run 真删孤儿；
6. 非标准 key（违反 media/{kind}/{id}/{variant} 契约）⇒ 退出码 1；
7. tmp/ 前缀不参与孤儿判定（临时对象本就允许存在）。
"""
import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.media import storage
from apps.media.models import MediaObject

PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c6300010000050001"
    "0d0a2db40000000049454e44ae426082"
)


def _hid(name: str) -> str:
    """把可读名映射成 32 位小写 hex —— 真实 media_id 是 uuid4().hex。

    审计命令会校验 key 形态，所以测试必须用**真实形态**的 id，
    否则连正常用例都会被判成「非标准 key」。
    """
    import hashlib

    return hashlib.md5(name.encode()).hexdigest()


def _mk(user, media_id, kind="image", with_thumb=True, expired=False):
    media_id = _hid(media_id)
    store = storage.get_storage()
    media = MediaObject.objects.create(
        media_id=media_id,
        owner=user,
        kind=kind,
        content_hash=f"h-{media_id}",
        mime_type="image/png",
        size=len(PNG),
        storage_path=storage.original_key(kind, media_id),
        status=MediaObject.STATUS_READY,
    )
    store.put(media.storage_path, PNG, "image/png")
    if with_thumb:
        media.thumbnail_path = storage.thumbnail_key(kind, media_id)
        store.put(media.thumbnail_path, PNG, "image/jpeg")
    if expired:
        media.expired_at = timezone.now()
    media.save()
    return media


def _audit(*extra):
    """执行审计命令，返回 (exit_code, stdout)。

    命令用 SystemExit(0/1) 表达结果，call_command 会把它转成异常，
    这里统一捕获成退出码。
    """
    from io import StringIO

    out = StringIO()
    code = 0
    try:
        call_command("media_audit", *extra, stdout=out, stderr=StringIO())
    except SystemExit as exc:  # noqa: PERF203
        code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue()


@pytest.mark.django_db
class TestMediaAudit:
    def test_consistent_passes(self, user_factory):
        user = user_factory(username="au1")
        _mk(user, "au-ok")
        code, out = _audit()
        assert code == 0, out
        assert "PASS" in out

    def test_missing_object_detected(self, user_factory):
        user = user_factory(username="au2")
        media = _mk(user, "au-missing")
        storage.get_storage().delete(media.storage_path)
        code, out = _audit()
        assert code == 1
        assert media.storage_path in out
        assert "缺失" in out

    def test_expired_media_missing_is_not_a_problem(self, user_factory):
        """完全过期媒体的对象本就不该存在 —— 不能报成缺陷。"""
        user = user_factory(username="au3")
        media = _mk(user, "au-expired", expired=True)
        storage.get_storage().delete(media.storage_path)
        storage.get_storage().delete(media.thumbnail_path)
        code, out = _audit()
        assert code == 0, out

    def test_orphan_detected_and_preview_only(self, user_factory):
        user = user_factory(username="au4")
        _mk(user, "au-orphan-host")
        store = storage.get_storage()
        orphan_key = storage.original_key("image", "f" * 32)
        store.put(orphan_key, PNG, "image/png")

        code, out = _audit("--prune-orphans")
        assert code == 1
        assert orphan_key in out
        assert "预览" in out
        assert store.exists(orphan_key) is True, "默认必须只预览，不真删"

    def test_prune_orphans_deletes(self, user_factory):
        user = user_factory(username="au5")
        _mk(user, "au-prune-host")
        store = storage.get_storage()
        orphan_key = storage.original_key("image", "e" * 32)
        store.put(orphan_key, PNG, "image/png")

        _audit("--prune-orphans", "--no-dry-run")
        assert store.exists(orphan_key) is False

    def test_nonstandard_key_detected(self, user_factory):
        user = user_factory(username="au6")
        _mk(user, "au-std-host")
        store = storage.get_storage()
        # 违反契约：kind 不在枚举内 / media_id 不是 32 位 hex / variant 非法
        for bad in (
            "media/WRONG/abc/original",
            "media/image/not-hex/original",
            "media/image/" + "a" * 32 + "/cover",
            "media/image/" + "a" * 32,  # 缺 variant
        ):
            store.put(bad, PNG, "image/png")
        code, out = _audit()
        assert code == 1
        assert "非标准" in out

    def test_tmp_keys_are_allowed(self, user_factory):
        user = user_factory(username="au7")
        _mk(user, "au-tmp-host")
        store = storage.get_storage()
        store.put(storage.tmp_key("deadbeefdeadbeefdeadbeefdeadbeef"), PNG, "image/png")
        code, out = _audit()
        assert code == 0, out
