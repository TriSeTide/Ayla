"""media 测试辅助：与 chat/tests/helpers.py 对齐的 JWT 客户端工具。"""


def auth_as(user):
    """给任意用户建一个带 JWT 的 APIClient（与 chat.tests.helpers 一致）。"""
    from rest_framework.test import APIClient
    from rest_framework_simplejwt.tokens import RefreshToken

    client = APIClient()
    token = RefreshToken.for_user(user)
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token.access_token}")
    client.user = user
    return client
