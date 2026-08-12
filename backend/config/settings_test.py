"""测试专用 settings：不依赖 Redis/MySQL 即可跑通全部契约测试。

在 pytest 中通过 DJANGO_SETTINGS_MODULE 指向本模块（见 pyproject.toml）。
"""
from .settings import *  # noqa: F401,F403

# 内存缓存，替代 RedisCache
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "elysia-test",
    }
}

# InMemory channel layer，替代 RedisChannelLayer
CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels.layers.InMemoryChannelLayer",
        "CONFIG": {},
    }
}

# 数据库用内存 SQLite，测试间隔离
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}

DEBUG = False

# 测试环境不内嵌启动 SSE 出站投影（避免测试触发 lifespan 时连接真实 Elysium）
ELYSIA_BRIDGE_INLINE = False

# 测试用内存 FakeStorage，不依赖真实 MinIO（M4-3）
S3_STORAGE_BACKEND = "fake"

# 测试 SRS API 指向假地址：契约测试全部注入 FakeSrsClient（apps/live/tests/conftest.py），
# 假地址只作"未注入 fake 时快速失败"的保险，绝不触网、不误判"未在播"。
SRS_API_URL = "http://srs-test.invalid:1985"
SRS_QUERY_TIMEOUT = 0.1

# 日志压缩，测试输出干净
LOGGING = {
    "version": 1,
    "disable_existing_loggers": True,
    "handlers": {"null": {"class": "logging.NullHandler"}},
    "root": {"handlers": ["null"], "level": "CRITICAL"},
}
