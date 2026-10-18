"""``GET /api/v1/updates/check/`` 契约测试。"""
import json
from pathlib import Path

import pytest
from django.test import override_settings

from apps.releases import services


def _manifest_body(**overrides):
    release = {
        "release_id": "stable-1.0.1-2",
        "version": "1.0.1",
        "build": 2,
        "published_at": "2026-10-18T12:00:00Z",
        "notes": "修复若干问题",
        "mandatory": False,
        "min_supported_build": 0,
        "artifacts": [
            {
                "platform": "windows",
                "arch": "x64",
                "kind": "zip",
                "path": "stable/windows/1.0.1+2/ayla.zip",
                "file_name": "ayla.zip",
                "size": 2048,
                "sha256": "b" * 64,
                "install_url": None,
            }
        ],
    }
    body = {
        "schema_version": 1,
        "channel": "stable",
        "generated_at": "2026-10-18T12:00:00Z",
        "releases": [release],
    }
    body.update(overrides)
    return body


def _write(tmp_path: Path, data) -> None:
    (tmp_path / "manifest-stable.json").write_text(
        json.dumps(data, ensure_ascii=False), encoding="utf-8"
    )


@pytest.mark.django_db
def test_check_requires_no_auth_and_returns_update(api_client, tmp_path):
    _write(tmp_path, _manifest_body())
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        resp = api_client.get(
            "/api/v1/updates/check/",
            {
                "channel": "stable",
                "platform": "windows",
                "arch": "x64",
                "version": "1.0.0",
                "build": "1",
            },
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["update_available"] is True
    assert body["latest"]["build"] == 2
    assert body["download"]["sha256"] == "b" * 64
    assert "path" not in body["download"]
    assert str(tmp_path) not in json.dumps(body)


@pytest.mark.django_db
def test_check_missing_manifest_is_degraded(api_client, tmp_path):
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        resp = api_client.get(
            "/api/v1/updates/check/",
            {"platform": "windows", "arch": "x64", "version": "1.0.0", "build": "1"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["degraded"] is True
    assert body["reason"] == "manifest_unavailable"
    assert body["update_available"] is False


@pytest.mark.django_db
def test_check_invalid_manifest_is_503(api_client, tmp_path):
    _write(tmp_path, _manifest_body(schema_version=99))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        resp = api_client.get(
            "/api/v1/updates/check/",
            {"platform": "windows", "arch": "x64", "version": "1.0.0", "build": "1"},
        )
    assert resp.status_code == 503
    assert resp.json()["code"] == "release_manifest_invalid"


@pytest.mark.django_db
@pytest.mark.parametrize(
    "query",
    [
        {"arch": "x64", "build": "1"},
        {"platform": "windows", "build": "-1"},
        {"platform": "windows", "build": "abc"},
        {"platform": "windows", "build": "1", "version": "x" * 65},
        {"platform": "windows", "build": "1", "channel": "../evil"},
        [
            ("platform", "windows"),
            ("build", "1"),
            ("platform", "android"),
        ],
    ],
)
def test_check_rejects_invalid_request(api_client, tmp_path, query):
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        resp = api_client.get("/api/v1/updates/check/", query)
    assert resp.status_code == 400
    assert resp.json()["code"] == "invalid_request"


@pytest.mark.django_db
def test_check_invalid_platform_is_400_not_500(api_client, tmp_path):
    _write(tmp_path, _manifest_body())
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        resp = api_client.get(
            "/api/v1/updates/check/",
            {"platform": "playstation", "arch": "x64", "version": "1.0.0", "build": "1"},
        )
    assert resp.status_code == 400
    assert resp.json()["code"] == "invalid_request"
    assert "playstation" not in resp.json()["detail"]


def test_select_latest_is_pure_and_ordered():
    manifest = services.validate_manifest(_manifest_body(), expected_channel="stable")
    release, artifact = services.select_latest(manifest, platform="windows", arch="x64")
    assert release["build"] == 2
    assert artifact["kind"] == "zip"
