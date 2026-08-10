"""
Django settings —— Elysia 独立应用后端。

设计要点（继承上位规划）：
- 配置全部走环境变量（django-environ），不写死密钥/端口/账号；
- 默认值仅适合本地开发；生产必须显式提供 SECRET_KEY、数据库、Redis 等；
- Redis channel layer 为异步实时通信基座，测试中可被 InMemory 替换。
"""
from pathlib import Path

import environ

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(
    DEBUG=(bool, True),
    ALLOWED_HOSTS=(list, ["*"]),
    SECRET_KEY=(str, "dev-only-insecure-secret-key-change-me"),
)

env.read_env(BASE_DIR / ".env")

DEBUG = env.bool("DEBUG")
SECRET_KEY = env.str("SECRET_KEY")
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS")

# 以 config/ 为基准（backend/config/../ = backend/）
ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

INSTALLED_APPS = [
    "daphne",  # 必须放最前，接管 runserver 的 ASGI
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "channels",
    "rest_framework",
    "rest_framework_simplejwt",
    "apps.accounts",
    "apps.chat",
    "apps.elysia_bridge",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

# 数据库：本地开发默认 SQLite；生产走 MySQL 8（Docker Compose）。
DATABASES = {
    "default": {
        "ENGINE": env.str("DB_ENGINE", default="django.db.backends.sqlite3"),
        "NAME": env.str("DB_NAME", default=str(BASE_DIR / "db.sqlite3")),
        "USER": env.str("DB_USER", default=""),
        "PASSWORD": env.str("DB_PASSWORD", default=""),
        "HOST": env.str("DB_HOST", default=""),
        "PORT": env.str("DB_PORT", default=""),
        "CONN_MAX_AGE": env.int("DB_CONN_MAX_AGE", default=60),
        "OPTIONS": env.dict("DB_OPTIONS", default={}),
    }
}

REDIS_URL = env.str("REDIS_URL", default="redis://127.0.0.1:6379/0")

CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels_redis.core.RedisChannelLayer",
        "CONFIG": {
            "hosts": [REDIS_URL],
        },
    }
}

# 缓存：presence/在线状态/限流走 Redis；测试中用 LocMemCache 覆盖。
CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": REDIS_URL,
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
        "KEY_PREFIX": "elysia",
    }
}

AUTH_USER_MODEL = "accounts.User"

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

# Django REST Framework
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.IsAuthenticated",),
    "DEFAULT_RENDERER_CLASSES": ("rest_framework.renderers.JSONRenderer",),
    "EXCEPTION_HANDLER": "rest_framework.views.exception_handler",
}

# simplejwt
from datetime import timedelta  # noqa: E402

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(
        minutes=env.int("JWT_ACCESS_MINUTES", default=30)
    ),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=env.int("JWT_REFRESH_DAYS", default=7)),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": False,
}

# 国际化 / 时区
LANGUAGE_CODE = "zh-hans"
TIME_ZONE = env.str("TIME_ZONE", default="Asia/Shanghai")
USE_I18N = True
USE_TZ = True

# 聊天：消息撤回限时窗口（秒）
MESSAGE_RECALL_SECONDS = env.int("MESSAGE_RECALL_SECONDS", default=120)

# ---------- 爱莉桥接（M4-4） ----------
# ELYSIA_BASE_URL：阶段三 Elysium API 根地址（不含 /api/v1 前缀，客户端拼接）。
# ELYSIA_CREDENTIAL_FILE：service credential 一次性 secret 落盘路径（本机配置，
#   Git 忽略，不提交仓库；access/refresh token 只存内存，重启后用它重换 session）。
# ELYSIA_SSE_RECONNECT_SECONDS：SSE 断线重连的有界退避初始间隔。
ELYSIA_BASE_URL = env.str("ELYSIA_BASE_URL", default="")
ELYSIA_CREDENTIAL_FILE = env.str(
    "ELYSIA_CREDENTIAL_FILE",
    default=str(BASE_DIR / "runtime" / "elysia_credential.json"),
)
ELYSIA_SSE_RECONNECT_SECONDS = env.float("ELYSIA_SSE_RECONNECT_SECONDS", default=3.0)
ELYSIA_SSE_EVENT_TYPES = env.list(
    "ELYSIA_SSE_EVENT_TYPES", default=["chat.message"]
)

# 静态/媒体
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# 日志：结构化 JSON 可选；本地开发输出到控制台，错误留 traceback。
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "verbose": {
            "format": "{levelname} {asctime} {name} {message}",
            "style": "{",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "verbose",
        },
    },
    "root": {"handlers": ["console"], "level": env.str("LOG_LEVEL", default="INFO")},
}
