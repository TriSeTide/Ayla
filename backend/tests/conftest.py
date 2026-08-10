"""pytest 共享 fixtures。"""
import pytest
from rest_framework.test import APIClient


@pytest.fixture
def api_client() -> APIClient:
    """未认证客户端。"""
    return APIClient()


@pytest.fixture
def auth_client(db):
    """已认证客户端（新建用户 + JWT）。"""

    def _make(**user_kwargs):
        from django.contrib.auth import get_user_model

        User = get_user_model()
        username = user_kwargs.pop("username", "user")
        email = user_kwargs.pop("email", None) or f"{username}@test.local"
        password = user_kwargs.pop("password", "test-pass-123")
        user = User.objects.create_user(username=username, email=email, password=password)
        for k, v in user_kwargs.items():
            setattr(user, k, v)
        user.save()
        from rest_framework_simplejwt.tokens import RefreshToken

        token = RefreshToken.for_user(user)
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
        client.user = user
        return client, user

    return _make


@pytest.fixture
def user_factory(db):
    """创建任意用户的工厂。"""

    def _make(**user_kwargs):
        from django.contrib.auth import get_user_model

        User = get_user_model()
        username = user_kwargs.pop("username", None)
        if username is None:
            import uuid

            username = f"u_{uuid.uuid4().hex[:8]}"
        email = user_kwargs.pop("email", None) or f"{username}@test.local"
        password = user_kwargs.pop("password", "test-pass-123")
        user = User.objects.create_user(username=username, email=email, password=password)
        for k, v in user_kwargs.items():
            setattr(user, k, v)
        user.save()
        return user

    return _make
