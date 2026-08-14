"""注册 Favorite 便于后台排查。"""
from django.contrib import admin

from .models import Favorite


@admin.register(Favorite)
class FavoriteAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "target_type", "target_id", "created_at")
    list_filter = ("target_type", "created_at")
    search_fields = ("user__username", "user__nickname", "target_id")
