"""ElysiaProfile 模型契约测试（D-2 字段收敛后）。

覆盖：
- 创建：只保留 user/enabled/display_name/created_at（D-2 删了 stream_id /
  platform / chat_type，REQUIREMENTS.zh.md §13.4）；
- 唯一约束：一个 User 只能绑定一个 profile；
- 生命周期：enabled 可切换（服务层跳过语义在 test_inject 覆盖）；
- 关联：user 被删级联删除 profile；profile 绑定的是真实 User（可被搜索/私聊）；
- 已删字段与旧生成函数不得复活（防回归：serializers 的模块级 import 曾导致 URLconf 挂）。

主体性边界：display_name 只是应用侧 UI 字段，模型里没有「爱莉说过的内容」字段
—— 她的第一人称内容只来自她自己的意识实例经通道投递。
"""
import pytest
from django.contrib.auth import get_user_model
from django.db import IntegrityError

from apps.elysia_bridge import models as bridge_models
from apps.elysia_bridge.models import ElysiaProfile

User = get_user_model()


def _make_profile(user, **kw):
    return ElysiaProfile.objects.create(user=user, **kw)


@pytest.mark.django_db
class TestElysiaProfileModel:
    def test_create_with_defaults(self, user_factory):
        user = user_factory(username="elysia_core")
        p = _make_profile(user)

        assert p.enabled is True
        assert p.display_name == ""
        assert p.created_at is not None
        # 绑定的是真实 User，可被反向查询（FR-26：爱莉以真实用户存在）
        assert user.elysia_profile.id == p.id  # OneToOne 反向访问返回 profile 对象

    def test_removed_fields_are_gone(self, user_factory):
        """D-2 删除的字段不得复活（serializers 曾模块级 import 旧生成函数）。"""
        p = _make_profile(user_factory(username="elysia_gone"))
        for field in ("stream_id", "platform", "chat_type"):
            assert not hasattr(p, field), f"{field} 应已随 D-2 删除"
        assert not hasattr(bridge_models, "generate_elysia_stream_id")

    def test_removed_fields_rejected_on_create(self, user_factory):
        """旧调用方传 stream_id 必须显式报错，而不是静默接受。"""
        user = user_factory(username="elysia_reject")
        with pytest.raises(TypeError):
            ElysiaProfile.objects.create(user=user, stream_id="legacy")

    def test_unique_user(self, user_factory):
        user = user_factory(username="elysia_uniq_user")
        _make_profile(user)
        with pytest.raises(IntegrityError):
            _make_profile(user)

    def test_multiple_profiles_for_different_users(self, user_factory):
        u1 = user_factory(username="elysia_multi_1")
        u2 = user_factory(username="elysia_multi_2")
        p1 = _make_profile(u1)
        p2 = _make_profile(u2)
        assert ElysiaProfile.objects.count() == 2
        assert p1.id != p2.id

    def test_enabled_toggle(self, user_factory):
        p = _make_profile(user_factory(username="elysia_toggle"))
        assert p.enabled is True
        p.enabled = False
        p.save(update_fields=["enabled"])
        p.refresh_from_db()
        assert p.enabled is False

    def test_cascade_delete_with_user(self, user_factory):
        user = user_factory(username="elysia_cascade")
        p = _make_profile(user)
        user.delete()
        assert not ElysiaProfile.objects.filter(pk=p.id).exists()

    def test_display_name_never_persisted_to_elysium(self, user_factory):
        """display_name 只是应用侧 UI 字段（记录契约，不写回 Elysium）。"""
        p = _make_profile(user_factory(username="elysia_name"), display_name="爱莉")
        p.refresh_from_db()
        assert p.display_name == "爱莉"
        assert not hasattr(p, "content")
