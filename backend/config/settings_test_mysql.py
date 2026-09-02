"""测试专用 settings（MySQL 版）：继承 settings_test 的全部测试隔离，
仅把数据库换成 .env 里的 MySQL（JSON contains 等 SQLite 不支持的查询需要 MySQL）。

用法：pytest --ds=config.settings_test_mysql
"""
from .settings import env  # noqa: F401
from .settings_test import *  # noqa: F401,F403

# 数据库用 .env 的 MySQL（pytest-django 会自动创建 test_<DB_NAME> 测试库）
DATABASES = {
    "default": {
        "ENGINE": env.str("DB_ENGINE", default="django.db.backends.mysql"),
        "NAME": env.str("DB_NAME", default="ayla"),
        "USER": env.str("DB_USER", default="root"),
        "PASSWORD": env.str("DB_PASSWORD", default=""),
        "HOST": env.str("DB_HOST", default="127.0.0.1"),
        "PORT": env.str("DB_PORT", default="3306"),
        "CONN_MAX_AGE": 0,
        # 本机 MySQL 服务器默认引擎为 MyISAM（不支持 FK 约束），测试建表强制 InnoDB
        "OPTIONS": {
            "charset": "utf8mb4",
            "init_command": "SET default_storage_engine=InnoDB",
        },
    }
}
