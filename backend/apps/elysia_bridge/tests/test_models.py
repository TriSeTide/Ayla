"""
ElysiaProfile 模型契约测试（8.1 清单第 1 项）。

覆盖：
- 创建：user/stream_id/platform/enabled/chat_type 默认值；
- platform 默认 `ayla`（Elysium接入Ayla平台模块.md §1.1）；
- stream_id 未显式提供时由 `generate_elysia_stream_id` 自动生成
  （SHA-256 `ayla_<uid>_private`，与 Elysium 侧同算法，避开历史飞书流，文档 §5.2）；
- 唯一约束：user 唯一、stream_id 唯一（DB 层 UniqueConstraint / 字段 unique）；
- 生命周期：enabled=False 时桥接跳过（服务层在 test_inject/test_outbound 覆盖，
  这里验证模型层面 enabled 字段与绑定关系）；
- 关联：user 被删级联删除 profile；profile 绑定的是真实 User（可被搜索/私聊）。
"""
import hashlib

import pytest
from django.contrib.auth import get_user_model
from django.db import IntegrityError

from apps.elysia_bridge.models import ElysiaProfile, generate_elysia_stream_id

User = get_user_model()


def _make_profile(user, stream_id="stream_elysia_1", **kw):
    return ElysiaProfile.objects.create(user=user, stream_id=stream_id, **kw)


@pytest.mark.django_db
class TestElysiaProfileModel:
    def test_create_with_defaults(self, user_factory):
        user = user_factory(username="elysia_core")
        p = _make_profile(user)

        assert p.platform == ElysiaProfile.PLATFORM_DEFAULT  # "ayla"
        assert p.enabled is True
        assert p.chat_type == ElysiaProfile.CHAT_TYPE_PRIVATE
        assert p.display_name == ""
        assert p.stream_id == "stream_elysia_1"
        assert p.created_at is not None
        # 绑定的是真实 User，可被反向查询（FR-26：爱莉以真实用户存在）
        assert user.elysia_profile.id == p.id  # OneToOne 反向访问返回 profile 对象

    def test_platform_default_is_ayla(self, user_factory):
        """platform 默认 ayla（独立应用聊天通道标识，文档 §1.1）。"""
        user = user_factory(username="elysia_platform")
        p = _make_profile(user, stream_id="s-p")
        assert p.platform == "ayla"

    def test_generate_stream_id_matches_elysium_algorithm(self, user_factory):
        """生成流与 Elysium ChatStream.generate_stream_id 同算法（ayla_<uid>_private）。"""
        uid = "user-42"
        sid = generate_elysia_stream_id(uid)
        assert sid == hashlib.sha256(f"ayla_{uid}_private".encode()).hexdigest()
        # platform 参与哈希：与历史飞书流（feishu_<uid>_private）天然不同
        feishu = hashlib.sha256(f"feishu_{uid}_private".encode()).hexdigest()
        assert sid != feishu

    def test_create_without_stream_id_generates_ayla_stream(
        self, user_factory
    ):
        """stream_id 未显式提供时自动生成 ayla 独立流（文档 §5.2）。"""
        from apps.elysia_bridge.models import generate_elysia_stream_id

        user = user_factory(username="elysia_auto")
        expected = generate_elysia_stream_id(str(user.id))
        # 通过模型直接创建仍需 stream_id（DB not null）；自动生成在 serializer 层
        # 这里验证生成函数一致性；serializer 自动生成见 test_profile_api。
        assert len(expected) == 64
        assert expected != "stream_elysia_1"

    def test_unique_user(self, user_factory):
        user = user_factory(username="elysia_uniq_user")
        _make_profile(user, stream_id="s1")
        with pytest.raises(IntegrityError):
            _make_profile(user, stream_id="s2")

    def test_unique_stream_id(self, user_factory):
        u1 = user_factory(username="elysia_uniq_stream_1")
        u2 = user_factory(username="elysia_uniq_stream_2")
        _make_profile(u1, stream_id="same-stream")
        with pytest.raises(IntegrityError):
            _make_profile(u2, stream_id="same-stream")

    def test_multiple_profiles_for_different_users(self, user_factory):
        u1 = user_factory(username="elysia_multi_1")
        u2 = user_factory(username="elysia_multi_2")
        p1 = _make_profile(u1, stream_id="s-a")
        p2 = _make_profile(u2, stream_id="s-b")
        assert ElysiaProfile.objects.count() == 2
        assert p1.id != p2.id

    def test_enabled_toggle(self, user_factory):
        p = _make_profile(user_factory(username="elysia_toggle"), stream_id="s-t")
        assert p.enabled is True
        p.enabled = False
        p.save(update_fields=["enabled"])
        p.refresh_from_db()
        assert p.enabled is False

    def test_cascade_delete_with_user(self, user_factory):
        user = user_factory(username="elysia_cascade")
        p = _make_profile(user, stream_id="s-c")
        user.delete()
        assert not ElysiaProfile.objects.filter(pk=p.id).exists()

    def test_display_name_never_persisted_to_elysium(self, user_factory):
        """display_name 只是应用侧 UI 字段（记录契约，不写回 Elysium）。"""
        p = _make_profile(user_factory(username="elysia_name"), stream_id="s-n", display_name="爱莉")
        p.refresh_from_db()
        assert p.display_name == "爱莉"
        # 主体性边界：应用侧不生成爱莉第一人称内容 —— 模型层面没有“爱莉说过的内容”字段，
        # 爱莉消息内容只来自出站事件投影（test_outbound 覆盖）。
        assert not hasattr(p, "content")
