"""健康检查契约测试。"""
import pytest


@pytest.mark.django_db
class TestHealth:
    def test_live_probe(self, api_client):
        resp = api_client.get("/api/v1/health/live/")
        assert resp.status_code == 200
        assert resp.json()["status"] == "alive"

    def test_health_ok(self, api_client):
        resp = api_client.get("/api/v1/health/")
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "ok"
        assert body["checks"]["db"] == "ok"
        assert body["checks"]["cache"] == "ok"
