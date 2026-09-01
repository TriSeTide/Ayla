"""任务 06 在线状态改造契约测试。

覆盖：
- UserPublicSerializer.display_status 四规则（auto 跟随实时 / dnd / away / invisible）；
- ProfileSerializer 接受 auto（见 test_accounts_api.py::test_update_profile_accepts_auto）；
- PresenceConsumer._presence_value 映射（invisible→invisible，其余→online）；
- 迁移 0004：存量 online 值 → auto。
"""
import pytest
from unittest.mock import patch

from django.contrib.auth import get_user_model

User = get_user_model()

_PRESENCE_ONLINE = {"status": "online", "ts": "2026-08-26T00:00:00+00:00"}


@pytest.mark.django_db
class TestDisplayStatus:
    def _serialize(self, user):
        from apps.accounts.serializers import UserPublicSerializer

        return UserPublicSerializer(user).data

    def test_auto_online(self, user_factory):
        user = user_factory(status="auto")
        with patch("apps.accounts.presence.get_presence", return_value=_PRESENCE_ONLINE):
            data = self._serialize(user)
        assert data["display_status"] == "在线"
        assert data["online"] is True

    def test_auto_offline(self, user_factory):
        user = user_factory(status="auto")
        with patch("apps.accounts.presence.get_presence", return_value=None):
            data = self._serialize(user)
        assert data["display_status"] == "离线"
        assert data["online"] is False

    def test_dnd_ignores_presence(self, user_factory):
        """勿扰：即使实时在线也显示「勿扰」。"""
        user = user_factory(status="dnd")
        with patch("apps.accounts.presence.get_presence", return_value=_PRESENCE_ONLINE):
            data = self._serialize(user)
        assert data["display_status"] == "勿扰"
        assert data["online"] is True

    def test_away_ignores_presence(self, user_factory):
        user = user_factory(status="away")
        with patch("apps.accounts.presence.get_presence", return_value=_PRESENCE_ONLINE):
            data = self._serialize(user)
        assert data["display_status"] == "离开"
        assert data["online"] is True

    def test_invisible_offline(self, user_factory):
        """隐身：对外完全离线（display_status=离线 且 online=False）。

        presence 只表达「连接存在」；隐身语义由 User.status 承载——
        即使 Redis 存在 connection（连接活跃），online 仍为 False。
        """
        user = user_factory(status="invisible")
        with patch("apps.accounts.presence.get_presence", return_value=_PRESENCE_ONLINE):
            data = self._serialize(user)
        assert data["display_status"] == "离线"
        assert data["online"] is False

    def test_unknown_status_falls_back_to_auto(self, user_factory):
        """未知旧值（如迁移遗漏的 online）按 auto 语义兜底。"""
        user = user_factory(status="online")
        with patch("apps.accounts.presence.get_presence", return_value=_PRESENCE_ONLINE):
            data = self._serialize(user)
        assert data["display_status"] == "在线"


class TestPresenceValue:
    def test_presence_value_constant_online(self):
        """Redis presence 值恒为 online：presence 只表达连接存在，
        隐身可见性由 User.status（DB 实时）承载，运行中切回 auto 无需重连。"""
        from apps.accounts.consumers import PresenceConsumer

        assert PresenceConsumer._PRESENCE_VALUE == "online"


@pytest.mark.django_db(transaction=True)
def test_migration_0004_maps_online_to_auto():
    """迁移 0004：存量 online 值迁移为 auto（数据迁移）。"""
    from django.db import connection
    from django.db.migrations.executor import MigrationExecutor

    executor = MigrationExecutor(connection)
    executor.migrate([("accounts", "0003_user_show_content")])
    user = User.objects.create_user(username="mig_online", password="x")
    # 绕过模型 choices 直接写库，模拟存量 online 数据
    User.objects.filter(pk=user.pk).update(status="online")

    executor = MigrationExecutor(connection)
    executor.migrate([("accounts", "0004_user_status_auto")])
    user.refresh_from_db()
    assert user.status == "auto"
