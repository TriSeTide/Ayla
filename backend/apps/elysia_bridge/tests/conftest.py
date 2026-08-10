"""apps/elysia_bridge/tests 共享 fixtures：复用 backend/tests/conftest.py 的通用工厂。

pytest conftest 按目录作用域，apps/ 目录下看不到 tests/ 的 fixtures，
这里显式转发，避免重复定义。
"""
from tests.conftest import api_client, auth_client, user_factory  # noqa: F401
