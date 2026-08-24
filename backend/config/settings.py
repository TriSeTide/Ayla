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
    "apps.media",
    "apps.emoji",
    "apps.voice",
    "apps.live",
    "apps.posts",
    "apps.boardgame",
    "apps.search",
    "apps.favorites",
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

# ---------- 媒体（M4-3） ----------
# S3/MinIO 对象存储：全部走 env，默认值仅本地开发（与 docker-compose 默认一致）。
# S3_STORAGE_BACKEND=fake 时使用内存 FakeStorage（测试/无 MinIO 环境）。
S3_ENDPOINT_URL = env.str("S3_ENDPOINT_URL", default="http://127.0.0.1:9000")
S3_ACCESS_KEY = env.str("S3_ACCESS_KEY", default="elysia_minio")
S3_SECRET_KEY = env.str("S3_SECRET_KEY", default="elysia_minio_pass")
S3_BUCKET = env.str("S3_BUCKET", default="elysia-media")
S3_REGION = env.str("S3_REGION", default="us-east-1")
S3_PUBLIC = env.bool("S3_PUBLIC", default=False)  # 私密媒体，不得进入共享缓存
S3_STORAGE_BACKEND = env.str("S3_STORAGE_BACKEND", default="s3")

# 分类型大小上限（字节）；0 = 不设上限（图片/语音/视频按产品要求放开，file/emoji 仍受限）。
MEDIA_MAX_IMAGE_BYTES = env.int("MEDIA_MAX_IMAGE_BYTES", default=0)
MEDIA_MAX_VOICE_BYTES = env.int("MEDIA_MAX_VOICE_BYTES", default=0)
MEDIA_MAX_VIDEO_BYTES = env.int("MEDIA_MAX_VIDEO_BYTES", default=0)
MEDIA_MAX_FILE_BYTES = env.int("MEDIA_MAX_FILE_BYTES", default=50 * 1024 * 1024)
MEDIA_MAX_EMOJI_BYTES = env.int("MEDIA_MAX_EMOJI_BYTES", default=5 * 1024 * 1024)

# 媒体二进制走 PUT request.body；Django 默认 DATA_UPLOAD_MAX_MEMORY_SIZE=2.5MB
# 会在读取大请求体时直接抛 RequestDataTooBig，必须解除才能支持大图/长语音。
DATA_UPLOAD_MAX_MEMORY_SIZE = None

# 上传会话 TTL（秒）与缩略图长边（px）
MEDIA_TMP_TTL_SECONDS = env.int("MEDIA_TMP_TTL_SECONDS", default=600)
MEDIA_THUMB_MAX = env.int("MEDIA_THUMB_MAX", default=320)

# 大文件上传的本地中转临时目录（PUT 接收 / complete 校验的过路文件，传完即删）。
# 必须指向空间充足的数据盘：默认系统 Temp 在 C 盘，2.9G 视频上传峰值会在
# C 盘临时占用 3~6GB。backend/runtime 已 gitignore，不进仓库。
MEDIA_TMP_DIR = Path(
    env.str("MEDIA_TMP_DIR", default=str(BASE_DIR / "runtime" / "media_tmp"))
)
MEDIA_TMP_DIR.mkdir(parents=True, exist_ok=True)

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
# 内嵌出站投影：ASGI lifespan 启动时在 Ayla 后端进程内运行 run_bridge_loop
# （文件锁保证单实例）。关闭时需独立进程 `manage.py run_bridge`。
ELYSIA_BRIDGE_INLINE = env.bool("ELYSIA_BRIDGE_INLINE", default=True)

# 静态/媒体
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

# ---------- 语音频道（M4-5） ----------
# LiveKit SFU：自托管 LiveKit Server。API key/secret 走本机配置（Git 忽略），不提交仓库。
# LIVEKIT_WS_URL：前端连接 LiveKit 的 WS 地址（如 ws://127.0.0.1:7880）。
LIVEKIT_API_KEY = env.str("LIVEKIT_API_KEY", default="")
LIVEKIT_API_SECRET = env.str("LIVEKIT_API_SECRET", default="")
LIVEKIT_WS_URL = env.str("LIVEKIT_WS_URL", default="ws://127.0.0.1:7880")
LIVEKIT_TOKEN_TTL_SECONDS = env.int("LIVEKIT_TOKEN_TTL_SECONDS", default=600)
# presence 心跳超时：超过该秒数未心跳的成员被标记离开（后台任务 owner，见 apps/voice/services.py）
VOICE_MEMBER_TIMEOUT_SECONDS = env.int("VOICE_MEMBER_TIMEOUT_SECONDS", default=120)

# ---------- 直播（M4-6） ----------
# SRS 流媒体服务器（docker-compose `srs` 服务，镜像 ossrs/srs:5）。
# - SRS_API_URL：HTTP API 根（状态查询 /api/v1/streams、健康检查 /api/v1/versions）；
# - SRS_RTMP_URL / SRS_PLAY_URL：推流/播放地址前缀（stream_key 拼在其后）；
# - SRS_QUERY_TIMEOUT：状态查询短超时（Django 事件循环不做阻塞 I/O，查询走同步线程）。
# 默认值仅本地开发；真实部署以环境变量为准。
SRS_API_URL = env.str("SRS_API_URL", default="http://127.0.0.1:1985")
SRS_RTMP_URL = env.str("SRS_RTMP_URL", default="rtmp://127.0.0.1:1935/live")
SRS_PLAY_URL = env.str("SRS_PLAY_URL", default="http://127.0.0.1:8080/live")
SRS_QUERY_TIMEOUT = env.float("SRS_QUERY_TIMEOUT", default=2.0)
# 新进直播间历史弹幕条数（默认 50）
LIVE_DANMAKU_HISTORY_LIMIT = env.int("LIVE_DANMAKU_HISTORY_LIMIT", default=50)

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
