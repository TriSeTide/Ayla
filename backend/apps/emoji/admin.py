from django.contrib import admin

from .models import EmojiItem, EmojiPack


@admin.register(EmojiPack)
class EmojiPackAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "owner", "is_system", "created_at")
    search_fields = ("name",)
    list_filter = ("is_system",)


@admin.register(EmojiItem)
class EmojiItemAdmin(admin.ModelAdmin):
    list_display = ("id", "pack", "media", "tag", "created_at")
    search_fields = ("tag", "pack__name")
