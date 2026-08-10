"""accounts DRF 序列化器。"""
from django.contrib.auth import get_user_model
from django.db import transaction
from rest_framework import serializers

from .models import FriendRequest, Friendship

User = get_user_model()


class UserPublicSerializer(serializers.ModelSerializer):
    """对外公开的用户信息（不含密码/邮箱）。"""

    id = serializers.CharField(read_only=True)
    online = serializers.SerializerMethodField()

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
            "date_joined",
        ]
        read_only_fields = ["id", "date_joined"]

    def get_online(self, obj) -> bool:
        from .presence import get_presence

        return get_presence(obj.id) is not None


class RegisterSerializer(serializers.ModelSerializer):
    password = serializers.CharField(write_only=True, min_length=8)

    class Meta:
        model = User
        fields = ["username", "email", "password", "nickname"]

    def validate_username(self, value: str) -> str:
        if User.objects.filter(username=value).exists():
            raise serializers.ValidationError("用户名已存在")
        return value

    def validate_email(self, value: str) -> str:
        if User.objects.filter(email=value).exists():
            raise serializers.ValidationError("邮箱已被注册")
        return value

    @transaction.atomic
    def create(self, validated_data):
        nickname = validated_data.pop("nickname", "") or validated_data["username"]
        user = User(username=validated_data["username"], email=validated_data["email"])
        user.set_password(validated_data["password"])
        user.nickname = nickname
        user.save()
        return user


class ProfileSerializer(serializers.ModelSerializer):
    """个人资料（本人读写）。"""

    class Meta:
        model = User
        fields = ["nickname", "avatar", "signature", "status"]
        extra_kwargs = {
            "nickname": {"max_length": 64, "required": False},
            "avatar": {"max_length": 512, "required": False},
            "signature": {"max_length": 256, "required": False},
        }


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
    user = UserPublicSerializer(read_only=True)

    class Meta:
        model = Friendship
        fields = ["id", "user", "created_at"]
