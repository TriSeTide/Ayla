from django.contrib import admin

from .models import MediaObject, MediaUploadSession


@admin.register(MediaObject)
class MediaObjectAdmin(admin.ModelAdmin):
    list_display = ("media_id", "kind", "owner", "status", "size", "created_at")
    search_fields = ("media_id", "owner__username")
    list_filter = ("kind", "status")


@admin.register(MediaUploadSession)
class MediaUploadSessionAdmin(admin.ModelAdmin):
    list_display = ("upload_id", "owner", "kind", "status", "expires_at")
    search_fields = ("upload_id", "owner__username")
    list_filter = ("kind", "status")
