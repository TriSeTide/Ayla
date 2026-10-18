"""发布清单校验与更新选择契约测试。"""
import json
from pathlib import Path

import pytest
from django.test import override_settings

from apps.releases import services


def _artifact(**overrides):
    body = {
        "platform": "windows",
        "arch": "x64",
        "kind": "zip",
        "path": "stable/windows/1.0.1+2/ayla-windows-x64-1.0.1+2.zip",
        "file_name": "ayla-windows-x64-1.0.1+2.zip",
        "size": 1024,
        "sha256": "a" * 64,
        "install_url": None,
    }
    body.update(overrides)
    return body


def _release(**overrides):
    body = {
        "release_id": "stable-1.0.1-2",
        "version": "1.0.1",
        "build": 2,
        "published_at": "2026-10-18T12:00:00Z",
        "notes": "修复若干问题",
        "mandatory": False,
        "min_supported_build": 0,
        "artifacts": [_artifact()],
    }
    body.update(overrides)
    return body


def _manifest(*releases):
    return {
        "schema_version": 1,
        "channel": "stable",
        "generated_at": "2026-10-18T12:00:00Z",
        "releases": list(releases or (_release(),)),
    }


def _write(tmp_path: Path, data) -> Path:
    path = tmp_path / "manifest-stable.json"
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return path


def test_manifest_missing_is_unavailable_not_up_to_date(tmp_path):
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        with pytest.raises(services.ManifestUnavailable):
            services.load_manifest("stable")
        payload = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.0",
            current_build=1,
        )
    assert payload["degraded"] is True
    assert payload["reason"] == "manifest_unavailable"
    assert payload["update_available"] is False
    assert payload["latest"] is None


def test_manifest_valid_selects_newest_build(tmp_path):
    _write(
        tmp_path,
        _manifest(
            _release(release_id="r1", version="1.0.1", build=2),
            _release(
                release_id="r2",
                version="1.0.2",
                build=3,
                artifacts=[_artifact(path="stable/windows/1.0.2+3/a.zip")],
            ),
        ),
    )
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        payload = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.0",
            current_build=1,
        )
    assert payload["update_available"] is True
    assert payload["latest"]["build"] == 3
    assert payload["download"]["url"] == "/releases/stable/windows/1.0.2+3/a.zip"
    assert payload["mandatory"] is False
    assert payload["reason"] == "update_available"


def test_up_to_date_and_equal_build(tmp_path):
    _write(tmp_path, _manifest(_release(build=2)))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        payload = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.1",
            current_build=2,
        )
    assert payload["update_available"] is False
    assert payload["reason"] == "up_to_date"
    assert payload["latest"]["build"] == 2


def test_mandatory_when_flagged_or_below_min_supported(tmp_path):
    _write(tmp_path, _manifest(_release(build=4, mandatory=True)))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        flagged = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.0",
            current_build=1,
        )
    assert flagged["mandatory"] is True

    _write(tmp_path, _manifest(_release(build=5, min_supported_build=5)))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        too_old = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.0",
            current_build=1,
        )
    assert too_old["mandatory"] is True


def test_platform_without_artifact_has_no_update(tmp_path):
    _write(tmp_path, _manifest(_release()))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        payload = services.build_check_response(
            channel="stable",
            platform="android",
            arch="arm64",
            current_version="0.9.0",
            current_build=1,
        )
    assert payload["update_available"] is False
    assert payload["reason"] == "no_release_for_platform"
    assert payload["latest"] is None


def test_universal_arch_matches_any_client(tmp_path):
    artifact = _artifact(arch="universal")
    _write(tmp_path, _manifest(_release(artifacts=[artifact])))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        payload = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="arm64",
            current_version="0.9.0",
            current_build=1,
        )
    assert payload["update_available"] is True


def test_platform_falls_back_to_previous_release_when_latest_lacks_it(tmp_path):
    _write(
        tmp_path,
        _manifest(
            _release(
                release_id="windows-only",
                version="1.1.0",
                build=9,
                artifacts=[_artifact(path="stable/windows/1.1.0+9/w.zip")],
            ),
            _release(
                release_id="android-only",
                version="1.2.0",
                build=10,
                artifacts=[
                    _artifact(
                        platform="android",
                        arch="arm64",
                        kind="apk",
                        path="stable/android/1.2.0+10/a.apk",
                    )
                ],
            ),
        ),
    )
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        payload = services.build_check_response(
            channel="stable",
            platform="windows",
            arch="x64",
            current_version="1.0.0",
            current_build=1,
        )
    assert payload["latest"]["build"] == 9


@pytest.mark.parametrize(
    "mutate",
    [
        lambda data: data.update(schema_version=2),
        lambda data: data.update(channel="beta"),
        lambda data: data.update(releases="nope"),
        lambda data: data["releases"][0].update(build="2"),
        lambda data: data["releases"][0].update(build=0),
        lambda data: data["releases"][0].update(version=""),
        lambda data: data["releases"][0].update(artifacts=[]),
        lambda data: data["releases"][0]["artifacts"][0].update(platform="playstation"),
        lambda data: data["releases"][0]["artifacts"][0].update(sha256="zz"),
        lambda data: data["releases"][0]["artifacts"][0].update(path="../escape.zip"),
        lambda data: data["releases"][0]["artifacts"][0].update(path="/etc/passwd"),
        lambda data: data["releases"][0]["artifacts"][0].update(path="beta/x.zip"),
        lambda data: data["releases"][0]["artifacts"][0].update(size=0),
        lambda data: data["releases"][0]["artifacts"][0].update(
            install_url="javascript:alert(1)"
        ),
        lambda data: data["releases"].append(data["releases"][0].copy()),
    ],
)
def test_invalid_manifest_fails_closed(tmp_path, mutate):
    data = _manifest()
    mutate(data)
    _write(tmp_path, data)
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        with pytest.raises(services.ManifestInvalid):
            services.load_manifest("stable")


def test_malformed_json_and_bad_encoding(tmp_path):
    (tmp_path / "manifest-stable.json").write_text("{not json", encoding="utf-8")
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        with pytest.raises(services.ManifestInvalid):
            services.load_manifest("stable")
    (tmp_path / "manifest-stable.json").write_bytes(b"\xff\xfe")
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        with pytest.raises(services.ManifestInvalid):
            services.load_manifest("stable")


def test_manifest_size_limit(tmp_path):
    _write(tmp_path, _manifest())
    with override_settings(
        AYLA_RELEASES_DIR=str(tmp_path), AYLA_RELEASES_MAX_MANIFEST_BYTES=10
    ):
        with pytest.raises(services.ManifestInvalid):
            services.load_manifest("stable")


def test_channel_validation_rejects_traversal():
    for value in ("", "../x", "stable/../x", "Stable!x", "a" * 40):
        with pytest.raises(services.ManifestInvalid):
            services.validate_channel(value)
    assert services.validate_channel(" Stable ") == "stable"


def test_public_download_url_quotes_path_but_keeps_slashes():
    assert (
        services.public_download_url("stable/windows/a b.zip")
        == "/releases/stable/windows/a%20b.zip"
    )


def test_manifest_cache_invalidates_on_file_change(tmp_path):
    _write(tmp_path, _manifest(_release(build=2)))
    with override_settings(AYLA_RELEASES_DIR=str(tmp_path)):
        first = services.load_manifest("stable")
        assert first["releases"][0]["build"] == 2
        # 同尺寸但内容/版本变化 + mtime 显式推进 ⇒ 必须重读
        _write(tmp_path, _manifest(_release(build=2, version="1.0.9")))
        target = tmp_path / "manifest-stable.json"
        current = target.stat().st_mtime_ns
        import os

        os.utime(target, ns=(current + 1_000_000, current + 1_000_000))
        second = services.load_manifest("stable")
        assert second["releases"][0]["version"] == "1.0.9"
