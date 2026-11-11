"""accounts DRF 序列化器。"""
from django.contrib.auth import get_user_model
from django.db import transaction
from rest_framework import serializers

from .models import FriendRequest, Friendship
from .services.email_code import EmailCodeError, check_code, consume_code

User = get_user_model()


class UserPublicSerializer(serializers.ModelSerializer):
    """对外公开的用户信息（不含密码/邮箱）。"""

    id = serializers.CharField(read_only=True)
    online = serializers.SerializerMethodField()
    display_status = serializers.SerializerMethodField()
    show_content = serializers.BooleanField(read_only=True)

    class Meta:
        model = User
        fields = [
            "id",
            "username",
            "nickname",
            "avatar",
            "signature",
            "status",
            "online",
            "display_status",
            "date_joined",
            "is_in_voice",
            "voice_room_id",
            "is_live",
            "live_room_id",
            "show_content",
        ]
        read_only_fields = ["id", "date_joined"]

    @staticmethod
    def _is_online(obj) -> bool:
        """在线 = Ayla 前端 presence **或** ElyH 通道连接（两个独立标记源，取或）。

        隐身（invisible）只作用于 Ayla 前端自己的 presence——那套 key 由
        PresenceConsumer 维护，用户可自主隐身；**ElyH 标记不参与隐身判断**：
        爱莉没有"隐身"概念，ElyH 连着就是在线（规则三，用户定）。
        两套标记分离的理由见 presence.py 的 ElyH 段注释。
        """
        from .presence import get_presence, is_elyh_online

        if obj.status == User.STATUS_INVISIBLE:
            # 隐身的 Ayla presence 对外视为离线；ElyH 通道是另一条事实，不跟着隐身。
            return is_elyh_online(obj.id)
        return get_presence(obj.id) is not None or is_elyh_online(obj.id)

    def get_online(self, obj) -> bool:
        return self._is_online(obj)

    def get_display_status(self, obj) -> str:
        """对外显示文案（任务 06）：auto 跟随实时在线，dnd/away/invisible 固定文案。"""
        if obj.status == User.STATUS_DND:
            return "勿扰"
        if obj.status == User.STATUS_AWAY:
            return "离开"
        if obj.status == User.STATUS_INVISIBLE:
            # 隐身文案固定「离线」；唯一例外是 ElyH 通道仍连着（不参与隐身）。
            return "在线" if self._is_online(obj) else "离线"
        # auto（含未知旧值兜底）：Ayla presence 或 ElyH 通道任一在线即「在线」
        return "在线" if self._is_online(obj) else "离线"


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=8)
    # 邮箱验证：邮箱必填；注册必须携带 6 位验证码（由 send-email-code 接口发放）
    email = serializers.EmailField(write_only=True, required=True)
    code = serializers.CharField(write_only=True, required=True, min_length=6, max_length=6)

    class Meta:
        model = User
        fields = ["username", "email", "password", "nickname", "code"]

    def validate_username(self, value: str) -> str:
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError("用户名已存在")
        return value

    def validate_email(self, value: str) -> str:
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError("邮箱已被注册")
        return value

    def validate(self, attrs):
        # 验证码有效性检查（不消费；消费在 create 内与建号同事务，避免用户名冲突时烧掉验证码）
        if not check_code(attrs.get("email", ""), attrs.get("code", "")):
            raise serializers.ValidationError({"code": "验证码无效或已过期"})
        return attrs

    @transaction.atomic
    def create(self, validated_data):
        code = validated_data.pop("code")
        email = validated_data["email"]
        try:
            consume_code(email, code)
        except EmailCodeError as exc:
            raise serializers.ValidationError({"code": exc.detail}) from exc
        nickname = validated_data.pop("nickname", "") or validated_data["username"]
        user = User(username=validated_data["username"], email=email)
        user.set_password(validated_data["password"])
        user.nickname = nickname
        user.save()
        return user


class ProfileSerializer(serializers.ModelSerializer):
    """个人资料（本人读写）。"""

    class Meta:
        model = User
        fields = ["nickname", "avatar", "signature", "status", "show_content"]
        extra_kwargs = {
            "nickname": {"max_length": 64, "required": False},
            "avatar": {"max_length": 512, "required": False},
            "signature": {"max_length": 256, "required": False},
            "show_content": {"required": False},
        }

    def validate_avatar(self, value):
        """头像必须是媒体 content URL 且当前用户有访问权（图片）；空串允许（清除）。"""
        from apps.media.services import validate_avatar_url

        user = getattr(self.context.get("request"), "user", None)
        error = validate_avatar_url(user, value)
        if error:
            raise serializers.ValidationError(error)
        return value


class FriendRequestSerializer(serializers.ModelSerializer):
    id = serializers.IntegerField(read_only=True)
    from_user = UserPublicSerializer(read_only=True)
    to_user = UserPublicSerializer(read_only=True)
    to_user_id = serializers.CharField(write_only=True)
    status = serializers.ChoiceField(
        choices=FriendRequest.STATUS_CHOICES, read_only=True
    )
    created_at = serializers.DateTimeField(read_only=True)

    class Meta:
        model = FriendRequest
        fields = [
            "id",
            "from_user",
            "to_user",
            "to_user_id",
            "message",
            "status",
            "created_at",
            "handled_at",
        ]

    def validate_to_user_id(self, value: str) -> str:
        if value == self.context["request"].user.id:
            raise serializers.ValidationError("不能添加自己为好友")
        try:
            User.objects.get(pk=value)
        except User.DoesNotExist:
            raise serializers.ValidationError("目标用户不存在")
        return value

    @transaction.atomic
    def create(self, validated_data):
        from_user = self.context["request"].user
        to_user_id = validated_data.pop("to_user_id")

        # 已存在好友关系则拒绝
        if Friendship.objects.filter(user=from_user, friend_id=to_user_id).exists():
            raise serializers.ValidationError("已是好友")

        # 存在待处理申请则复用
        existing = FriendRequest.objects.filter(
            from_user=from_user, to_user_id=to_user_id, status="pending"
        ).first()
        if existing:
            return existing

        return FriendRequest.objects.create(
            from_user=from_user, to_user_id=to_user_id, **validated_data
        )


class FriendRequestActionSerializer(serializers.Serializer):
    """同意/拒绝好友申请。"""

    action = serializers.ChoiceField(choices=["accept", "reject"])


class FriendshipSerializer(serializers.ModelSerializer):
    user = UserPublicSerializer(source="friend", read_only=True)

    class Meta:
        model = Friendship
        fields = ["id", "user", "created_at"]
