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

# 日志压缩，测试输出干净
LOGGING = {
    "version": 1,
    "disable_existing_loggers": True,
    "handlers": {"null": {"class": "logging.NullHandler"}},
    "root": {"handlers": ["null"], "level": "CRITICAL"},
}
