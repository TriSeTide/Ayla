"""apps/accounts/tests 共享 fixtures：复用 backend/tests/conftest.py 的通用工厂。"""
import pytest

from tests.conftest import api_client, auth_client, user_factory  # noqa: F401
