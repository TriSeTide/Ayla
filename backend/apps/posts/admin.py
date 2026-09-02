from django.contrib import admin

from .models import Comment, Post, PostImage, PostView


@admin.register(Post)
class PostAdmin(admin.ModelAdmin):
    list_display = ("id", "owner", "visibility", "group", "title", "created_at")
    search_fields = ("title", "body", "owner__username")
    list_filter = ("visibility", "created_at")


@admin.register(PostImage)
class PostImageAdmin(admin.ModelAdmin):
    list_display = ("id", "post", "media", "order")
    list_filter = ("post",)


@admin.register(Comment)
class CommentAdmin(admin.ModelAdmin):
    list_display = ("id", "post", "author", "created_at")
    search_fields = ("body", "author__username")
    list_filter = ("post", "created_at")


@admin.register(PostView)
class PostViewAdmin(admin.ModelAdmin):
    list_display = ("id", "post", "user", "viewed_at")
    list_filter = ("viewed_at",)
    search_fields = ("post__title", "user__username")
