"""WSGI 入口（Django 同步服务，生产可由 uvicorn/daphne 直接跑 ASGI）。"""
import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

from django.core.wsgi import get_wsgi_application  # noqa: E402

application = get_wsgi_application()
