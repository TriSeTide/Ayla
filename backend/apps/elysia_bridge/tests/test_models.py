"""
ElysiaProfile 模型契约测试（8.1 清单第 1 项）。

覆盖：
- 创建：user/stream_id/platform/enabled/chat_type 默认值；
- 唯一约束：user 唯一、stream_id 唯一（DB 层 UniqueConstraint / 字段 unique）；
- 生命周期：enabled=False 时桥接跳过（服务层在 test_inject/test_outbound 覆盖，
  这里验证模型层面 enabled 字段与绑定关系）；
- 关联：user 被删级联删除 profile；profile 绑定的是真实 User（可被搜索/私聊）。
"""
import pytest
from django.contrib.auth import get_user_model
from django.db import IntegrityError

from apps.elysia_bridge.models import ElysiaProfile

User = get_user_model()


def _make_profile(user, stream_id="stream_elysia_1", **kw):
    return ElysiaProfile.objects.create(user=user, stream_id=stream_id, **kw)


@pytest.mark.django_db
class TestElysiaProfileModel:
    def test_create_with_defaults(self, user_factory):
        user = user_factory(username="elysia_core")
        p = _make_profile(user)

        assert p.platform == ElysiaProfile.PLATFORM_DEFAULT  # "elysia-app"
        assert p.enabled is True
        assert p.chat_type == ElysiaProfile.CHAT_TYPE_PRIVATE
        assert p.display_name == ""
        assert p.stream_id == "stream_elysia_1"
        assert p.created_at is not None
        # 绑定的是真实 User，可被反向查询（FR-26：爱莉以真实用户存在）
        assert user.elysia_profile.id == p.id  # OneToOne 反向访问返回 profile 对象

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
