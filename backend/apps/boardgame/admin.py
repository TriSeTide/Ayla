from django.contrib import admin

from .models import GameRoom, GameRoomMember


@admin.register(GameRoom)
class GameRoomAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "owner", "visibility", "group", "game_type", "status", "created_at")
    search_fields = ("name", "owner__username")
    list_filter = ("visibility", "status", "game_type")


@admin.register(GameRoomMember)
class GameRoomMemberAdmin(admin.ModelAdmin):
    list_display = ("id", "room", "user", "seat", "joined_at")
    list_filter = ("room",)
