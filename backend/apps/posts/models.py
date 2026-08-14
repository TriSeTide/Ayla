"""
帖子域模型（S3，开发文档 §1.3）。

- Post：帖子。字段名用 `owner`（而非 `author`）是为了复用 `apps/common/visibility.py`
  的 `visible_queryset`/`can_view`/`can_join`（helper 硬编码 owner/visibility/group 三字段，
  §1.1 明确 live/voice/post/boardgame 同构复用）；对外序列化输出 `author`/`author_id`，
  保持帖子语义的"作者"表达（见 serializers.py）。
- PostImage：帖子配图（复用 media 三步上传，FK 到 media.MediaObject，`order` 定序）；
- Comment：评论（author/body/reply_to 可空，支持回复）。

权限语义（工程约束，AGENTS.md §2.2）：
- 信息流/详情/评论列表按可见性过滤（public 全登录 / friends 好友 / group 群员）；
- PATCH/DELETE 帖子仅 author（owner）；
- DELETE 评论仅评论作者本人。
"""
from django.conf import settings
from django.db import models

from apps.common.visibility import Visibility


class Post(models.Model):
    """帖子。"""

    id = models.AutoField(primary_key=True)
    # 作者：字段名 owner 以复用可见性 helper（§1.1 同构）；对外输出 author/author_id。
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="posts",
        on_delete=models.CASCADE,
    )
    # 群归属：可空；非空时默认 visibility=group（services 层落值，见 apps/posts/services.py）。
    group = models.ForeignKey(
        "chat.Conversation",
        related_name="posts",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        limit_choices_to={"type": "group"},
    )
    visibility = models.CharField(
        "可见性", max_length=16, choices=Visibility.choices, default=Visibility.PUBLIC
    )
    title = models.CharField("标题", max_length=128, blank=True, default="")
    body = models.TextField("正文", blank=True, default="")
    created_at = models.DateTimeField("创建时间", auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField("更新时间", auto_now=True)

    class Meta:
        db_table = "posts"
        verbose_name = "帖子"
        verbose_name_plural = "帖子"
        ordering = ["-created_at", "-id"]
        indexes = [
            models.Index(fields=["owner"], name="posts_owner_idx"),
            models.Index(fields=["group"], name="posts_group_idx"),
            models.Index(fields=["created_at"], name="posts_created_idx"),
        ]

    def __str__(self) -> str:
        return f"post{self.id}:{self.title or self.body[:20]}"


class PostImage(models.Model):
    """帖子配图（media 三步上传产物的引用，order 定序）。"""

    id = models.AutoField(primary_key=True)
    post = models.ForeignKey(Post, related_name="images", on_delete=models.CASCADE)
    media = models.ForeignKey(
        "media.MediaObject",
        related_name="post_images",
        on_delete=models.CASCADE,
    )
    order = models.PositiveIntegerField("顺序", default=0)

    class Meta:
        db_table = "post_images"
        verbose_name = "帖子配图"
        verbose_name_plural = "帖子配图"
        ordering = ["order", "id"]

    def __str__(self) -> str:
        return f"post{self.post_id}:img{self.order}"


class Comment(models.Model):
    """评论（支持 reply_to 回复）。"""

    id = models.AutoField(primary_key=True)
    post = models.ForeignKey(Post, related_name="comments", on_delete=models.CASCADE)
    author = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="post_comments",
        on_delete=models.CASCADE,
    )
    body = models.TextField("评论内容")
    reply_to = models.ForeignKey(
        "self",
        related_name="replies",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
    )
    created_at = models.DateTimeField("评论时间", auto_now_add=True, db_index=True)

    class Meta:
        db_table = "post_comments"
        verbose_name = "评论"
        verbose_name_plural = "评论"
        ordering = ["created_at", "id"]

    def __str__(self) -> str:
        return f"comment{self.id}:{self.body[:20]}"
