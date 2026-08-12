"""可选：注册 LiveChannel / Danmaku 便于后台排查（M4-6 §2）。"""
from django.contrib import admin

from .models import Danmaku, LiveChannel


@admin.register(LiveChannel)
class LiveChannelAdmin(admin.ModelAdmin):
    list_display = ("id", "title", "owner", "status", "started_at", "ended_at", "created_at")
    list_filter = ("status",)
    search_fields = ("title", "owner__username", "owner__nickname")
    # stream_key 属推流指纹，后台列表不展示明文，避免日志/审计泄漏
    readonly_fields = ("stream_key",)


@admin.register(Danmaku)
class DanmakuAdmin(admin.ModelAdmin):
    list_display = ("id", "channel", "sender", "content", "created_at")
    list_filter = ("created_at",)
    search_fields = ("content", "sender__username")
