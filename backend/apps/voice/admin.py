"""Django admin 注册（便于排查语音频道/成员）。"""
from django.contrib import admin

from .models import VoiceChannel, VoiceChannelMember


@admin.register(VoiceChannel)
class VoiceChannelAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "room_name", "owner", "created_at")
    search_fields = ("name", "room_name")


@admin.register(VoiceChannelMember)
class VoiceChannelMemberAdmin(admin.ModelAdmin):
    list_display = ("id", "channel", "user", "joined_at", "last_seen_at")
    list_filter = ("channel",)
