"""publish_release.py 纯函数契约（不触网、不构建）。"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import publish_release as pr  # noqa: E402


def test_normalize_version_accepts_plus_build():
    assert pr.normalize_version("1.2.3", 4) == ("1.2.3", 4)
    assert pr.normalize_version("1.2.3+9", 1) == ("1.2.3", 9)
    with pytest.raises(pr.ReleaseError):
        pr.normalize_version("", 1)
    with pytest.raises(pr.ReleaseError):
        pr.normalize_version("1.0.0", 0)


def test_validate_manifest_accepts_and_rejects():
    artifact = {
        "platform": "windows",
        "arch": "x64",
        "kind": "zip",
        "path": "stable/windows/1.0.0+1/a.zip",
        "file_name": "a.zip",
        "size": 10,
        "sha256": "a" * 64,
        "install_url": None,
    }
    manifest = {
        "schema_version": 1,
        "channel": "stable",
        "generated_at": "",
        "releases": [
            {
                "release_id": "stable-1.0.0-1",
                "version": "1.0.0",
                "build": 1,
                "published_at": "2026-10-18T00:00:00+00:00",
                "notes": "",
                "mandatory": False,
                "min_supported_build": 0,
                "artifacts": [artifact],
            }
        ],
    }
    pr.validate_manifest(manifest, "stable")
    bad = json.loads(json.dumps(manifest))
    bad["releases"][0]["artifacts"][0]["path"] = "../escape.zip"
    with pytest.raises(pr.ReleaseError):
        pr.validate_manifest(bad, "stable")
    bad2 = json.loads(json.dumps(manifest))
    bad2["releases"].append(dict(bad2["releases"][0]))
    with pytest.raises(pr.ReleaseError):
        pr.validate_manifest(bad2, "stable")


def test_artifact_entries_use_channel_and_release_dir(tmp_path):
    artifact = tmp_path / "ayla-windows-x64-1.0.0+1.zip"
    artifact.write_bytes(b"12345")
    entries = pr.artifact_entries(
        "stable", "1.0.0", 1, {"windows": artifact}, None
    )
    assert len(entries) == 1
    entry = entries[0]
    assert entry["path"] == "stable/windows/1.0.0+1/" + artifact.name
    assert entry["size"] == 5
    assert entry["sha256"] == "5994471abb01112afcc18159f6cc74b4f511b99806da59b3caf5a9c173cacfc5"


def test_artifact_entries_prefer_built_over_artifacts_dir(tmp_path):
    built = tmp_path / "built.apk"
    built.write_bytes(b"x")
    extra = tmp_path / "extra"
    extra.mkdir()
    (extra / "ayla-android-universal-9.apk").write_bytes(b"y")
    entries = pr.artifact_entries("beta", "2.0.0", 9, {"android": built}, extra)
    assert entries[0]["path"].startswith("beta/android/2.0.0+9/")
    assert entries[0]["file_name"] == "built.apk"


def test_parse_platforms():
    assert pr.parse_platforms("windows,android") == ["windows", "android"]
    with pytest.raises(pr.ReleaseError):
        pr.parse_platforms("")
    with pytest.raises(pr.ReleaseError):
        pr.parse_platforms("windows,toaster")


def test_cli_help_exits_zero(capsys):
    with pytest.raises(SystemExit) as exc:
        pr.main(["--help"])
    assert exc.value.code == 0
