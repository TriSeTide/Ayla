"""apps/accounts/tests 共享 fixtures：复用 backend/tests/conftest.py 的通用工厂。"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401


class FakePresenceRedis:
    """最小 Redis 假实现：只覆盖 presence 连接集合用到的方法。

    返回值语义与 redis-py 保持一致（bytes / set），让解码路径被真正走到；
    测试不依赖真实 Redis（与 `apps/live/tests/test_viewers.py::FakeRedis` 同款做法）。
    """

    def __init__(self):
        self.strings: dict[str, bytes] = {}
        self.ttls: dict[str, int] = {}
        self.sets: dict[str, set[bytes]] = {}
        self.hashes: dict[str, dict[bytes, bytes]] = {}

    @staticmethod
    def _b(value) -> bytes:
        return value if isinstance(value, bytes) else str(value).encode()

    def _setex(self, key, value: bytes, ttl: int) -> None:
        self.strings[key] = value
        self.ttls[key] = ttl

    # --- string ---
    def setex(self, key, ttl, value):
        self._setex(key, self._b(value), ttl)
        return True

    def set(self, key, value):
        self.strings[key] = self._b(value)
        return True

    def get(self, key):
        return self.strings.get(key)

    def exists(self, *keys):
        return sum(
            1
            for key in keys
            if key in self.strings or key in self.sets or key in self.hashes
        )

    def delete(self, *keys):
        removed = 0
        for key in keys:
            removed += any(
                storage.pop(key, None) is not None
                for storage in (self.strings, self.sets, self.hashes)
            )
            self.ttls.pop(key, None)
        return removed

    def expire(self, key, ttl):
        if key in self.strings or key in self.sets or key in self.hashes:
            self.ttls[key] = ttl
            return True
        return False

    # --- set ---
    def sadd(self, key, *members):
        bucket = self.sets.setdefault(key, set())
        added = 0
        for member in members:
            raw = self._b(member)
            if raw not in bucket:
                bucket.add(raw)
                added += 1
        return added

    def srem(self, key, *members):
        bucket = self.sets.get(key, set())
        removed = 0
        for member in members:
            raw = self._b(member)
            if raw in bucket:
                bucket.remove(raw)
                removed += 1
        return removed

    def smembers(self, key):
        return set(self.sets.get(key, set()))

    # --- hash ---
    def hset(self, key, field, value):
        self.hashes.setdefault(key, {})[self._b(field)] = self._b(value)
        return 1

    def hget(self, key, field):
        return self.hashes.get(key, {}).get(self._b(field))

    def hdel(self, key, *fields):
        bucket = self.hashes.get(key, {})
        removed = 0
        for field in fields:
            if bucket.pop(self._b(field), None) is not None:
                removed += 1
        return removed


@pytest.fixture
def fake_presence_redis(monkeypatch) -> FakePresenceRedis:
    """把 `apps.accounts.presence` 的 Redis 客户端换成内存假实现。

    每个用例独立实例 ⇒ 跨用例不串状态（presence 是进程外状态，不用 DB 隔离）。
    """
    from apps.accounts import presence

    fake = FakePresenceRedis()
    monkeypatch.setattr(presence, "_redis_client", lambda: fake)
    # 兼容 from-import 的调用点（consumers.py 里 clear/set 是直接引用的函数，
    # 这里换的是底层客户端，不影响函数引用）
    return fake
