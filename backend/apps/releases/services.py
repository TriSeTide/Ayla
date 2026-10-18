"""发布清单（release manifest）的读取、校验与更新选择。

设计边界
--------
- 发布产物由 ``Ayla/scripts/publish_release.py`` 上传到 SSH 服务器上的
  ``ayla-deploy/releases/``；本模块只读该目录里的 ``manifest-<channel>.json``。
- 清单是唯一的发布事实源：不建数据库表，不在后端拼接“猜测”的结果。
- 任何字段不合法都 fail-closed（``ManifestInvalid``），不静默跳过、不把损坏的
  清单解释成“没有更新”。清单缺失单独抛 ``ManifestUnavailable``，由 API 返回
  ``degraded`` 状态，绝不冒充“已是最新”。
- 路径只允许运行目录内的相对 POSIX 路径；绝对路径、``..``、反斜杠一律拒绝。

清单 schema（v1）::

    {
      "schema_version": 1,
      "channel": "stable",
      "generated_at": "2026-10-18T12:00:00Z",
      "releases": [
        {
          "release_id": "stable-1.0.1-2",
          "version": "1.0.1",
          "build": 2,
          "published_at": "2026-10-18T12:00:00Z",
          "notes": "……",
          "mandatory": false,
          "min_supported_build": 0,
          "artifacts": [
            {
              "platform": "windows",
              "arch": "x64",
              "kind": "zip",
              "path": "stable/windows/1.0.1+2/ayla-windows-x64-1.0.1+2.zip",
              "file_name": "ayla-windows-x64-1.0.1+2.zip",
              "size": 40000000,
              "sha256": "<64 hex>",
              "install_url": null
            }
          ]
        }
      ]
    }
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote

from django.conf import settings

logger = logging.getLogger(__name__)

SCHEMA_VERSION = 1
DEFAULT_CHANNEL = "stable"
MAX_RELEASES = 500
MAX_ARTIFACTS_PER_RELEASE = 32
MAX_MANIFEST_BYTES = 512 * 1024
MAX_NOTES_LENGTH = 8000
MAX_RELEASE_ID_LENGTH = 128
MAX_PATH_LENGTH = 512
MAX_FILE_NAME_LENGTH = 255
MAX_INSTALL_URL_LENGTH = 2048

_CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
_PLATFORM_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
_ARCH_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
_KIND_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
_VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_INSTALL_URL_RE = re.compile(r"^(https?|itms-services)://", re.IGNORECASE)

ALLOWED_PLATFORMS = frozenset({"windows", "android", "ios", "macos", "linux", "web"})
UNIVERSAL_ARCHES = frozenset({"", "any", "universal"})


class ManifestError(Exception):
    """发布清单错误基类（消息只用于服务端日志，不直接返回给客户端）。"""


class ManifestUnavailable(ManifestError):
    """清单文件不存在或不可读（配置/部署问题，不是“没有更新”）。"""


class ManifestInvalid(ManifestError):
    """清单存在但 schema/字段不合法。"""


def validate_channel(channel: str) -> str:
    value = (channel or "").strip().lower()
    if not _CHANNEL_RE.fullmatch(value):
        raise ManifestInvalid("channel 不合法")
    return value


def validate_platform(platform: str) -> str:
    value = (platform or "").strip().lower()
    if not _PLATFORM_RE.fullmatch(value) or value not in ALLOWED_PLATFORMS:
        raise ManifestInvalid("platform 不合法")
    return value


def validate_arch(arch: str) -> str:
    value = (arch or "").strip().lower()
    if not value:
        return ""
    if not _ARCH_RE.fullmatch(value):
        raise ManifestInvalid("arch 不合法")
    return value


def releases_dir() -> Path:
    """当前只读发布目录（允许在测试里用 override_settings 替换）。"""
    return Path(str(getattr(settings, "AYLA_RELEASES_DIR", ""))).expanduser()


def manifest_path(channel: str) -> Path:
    return releases_dir() / f"manifest-{validate_channel(channel)}.json"


def _as_dict(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestInvalid(f"{name} 必须是对象")
    return value


def _as_int(value: Any, name: str, *, minimum: int = 0, maximum: int = 2**31 - 1) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ManifestInvalid(f"{name} 必须是整数")
    if value < minimum or value > maximum:
        raise ManifestInvalid(f"{name} 超出范围")
    return value


def _as_bool(value: Any, name: str, *, default: bool = False) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise ManifestInvalid(f"{name} 必须是布尔值")
    return value


def _as_text(value: Any, name: str, *, max_length: int, required: bool = True) -> str:
    if value is None:
        if required:
            raise ManifestInvalid(f"{name} 不能为空")
        return ""
    if not isinstance(value, str):
        raise ManifestInvalid(f"{name} 必须是字符串")
    text = value.strip()
    if required and not text:
        raise ManifestInvalid(f"{name} 不能为空")
    if len(text) > max_length:
        raise ManifestInvalid(f"{name} 过长")
    return text


def _validate_relative_path(path: str) -> str:
    text = _as_text(path, "artifact.path", max_length=MAX_PATH_LENGTH)
    if "\\" in text or "\x00" in text:
        raise ManifestInvalid("artifact.path 不得包含反斜杠或 NUL")
    pure = PurePosixPath(text)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise ManifestInvalid("artifact.path 必须是运行目录内的相对路径")
    return pure.as_posix()


def _validate_install_url(value: Any) -> str | None:
    if value is None:
        return None
    text = _as_text(value, "artifact.install_url", max_length=MAX_INSTALL_URL_LENGTH)
    if not _INSTALL_URL_RE.match(text):
        raise ManifestInvalid("artifact.install_url scheme 不合法")
    return text


def _normalize_artifact(raw: dict[str, Any], *, channel: str) -> dict[str, Any]:
    platform = _as_text(raw.get("platform"), "artifact.platform", max_length=32).lower()
    if not _PLATFORM_RE.fullmatch(platform) or platform not in ALLOWED_PLATFORMS:
        raise ManifestInvalid("artifact.platform 不合法")
    arch = _as_text(raw.get("arch", "universal"), "artifact.arch", max_length=32).lower()
    if not _ARCH_RE.fullmatch(arch):
        raise ManifestInvalid("artifact.arch 不合法")
    kind = _as_text(raw.get("kind"), "artifact.kind", max_length=32).lower()
    if not _KIND_RE.fullmatch(kind):
        raise ManifestInvalid("artifact.kind 不合法")
    path = _validate_relative_path(raw.get("path"))
    if path.split("/", 1)[0] != channel:
        raise ManifestInvalid("artifact.path 必须以 channel 为根目录")
    file_name = _as_text(
        raw.get("file_name") or PurePosixPath(path).name,
        "artifact.file_name",
        max_length=MAX_FILE_NAME_LENGTH,
    )
    if "/" in file_name or "\\" in file_name or file_name in {".", ".."}:
        raise ManifestInvalid("artifact.file_name 不合法")
    size = _as_int(raw.get("size"), "artifact.size", minimum=1)
    sha256 = _as_text(raw.get("sha256"), "artifact.sha256", max_length=64).lower()
    if not _SHA256_RE.fullmatch(sha256):
        raise ManifestInvalid("artifact.sha256 必须是 64 位十六进制")
    install_url = _validate_install_url(raw.get("install_url"))
    return {
        "platform": platform,
        "arch": arch,
        "kind": kind,
        "path": path,
        "file_name": file_name,
        "size": size,
        "sha256": sha256,
        "install_url": install_url,
    }


def _normalize_release(raw: dict[str, Any], *, channel: str, index: int) -> dict[str, Any]:
    version = _as_text(raw.get("version"), f"releases[{index}].version", max_length=64)
    if not _VERSION_RE.fullmatch(version):
        raise ManifestInvalid("release.version 不合法")
    build = _as_int(raw.get("build"), f"releases[{index}].build", minimum=1)
    release_id = _as_text(
        raw.get("release_id") or f"{channel}-{version}-{build}",
        f"releases[{index}].release_id",
        max_length=MAX_RELEASE_ID_LENGTH,
    )
    published_at = _as_text(
        raw.get("published_at", ""),
        f"releases[{index}].published_at",
        max_length=64,
        required=False,
    )
    notes = _as_text(
        raw.get("notes", ""),
        f"releases[{index}].notes",
        max_length=MAX_NOTES_LENGTH,
        required=False,
    )
    mandatory = _as_bool(raw.get("mandatory", False), f"releases[{index}].mandatory")
    min_supported_build = _as_int(
        raw.get("min_supported_build", 0),
        f"releases[{index}].min_supported_build",
        minimum=0,
    )
    raw_artifacts = raw.get("artifacts")
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        raise ManifestInvalid("release.artifacts 必须是非空数组")
    if len(raw_artifacts) > MAX_ARTIFACTS_PER_RELEASE:
        raise ManifestInvalid("release.artifacts 过多")
    artifacts = [
        _normalize_artifact(_as_dict(item, "artifact"), channel=channel)
        for item in raw_artifacts
    ]
    seen: set[tuple[str, str]] = set()
    for artifact in artifacts:
        key = (artifact["platform"], artifact["arch"])
        if key in seen:
            raise ManifestInvalid("同一 release 内 platform/arch 重复")
        seen.add(key)
    return {
        "release_id": release_id,
        "version": version,
        "build": build,
        "published_at": published_at,
        "notes": notes,
        "mandatory": mandatory,
        "min_supported_build": min_supported_build,
        "artifacts": artifacts,
    }


def validate_manifest(data: Any, *, expected_channel: str) -> dict[str, Any]:
    """校验并归一化清单；不合法抛 ``ManifestInvalid``。"""
    root = _as_dict(data, "manifest")
    schema_version = _as_int(root.get("schema_version"), "schema_version", minimum=1, maximum=1)
    channel = validate_channel(_as_text(root.get("channel"), "channel", max_length=32))
    if channel != expected_channel:
        raise ManifestInvalid("manifest.channel 与请求 channel 不一致")
    generated_at = _as_text(
        root.get("generated_at", ""), "generated_at", max_length=64, required=False
    )
    raw_releases = root.get("releases")
    if not isinstance(raw_releases, list):
        raise ManifestInvalid("releases 必须是数组")
    if len(raw_releases) > MAX_RELEASES:
        raise ManifestInvalid("releases 过多")
    releases = [
        _normalize_release(_as_dict(item, "release"), channel=channel, index=index)
        for index, item in enumerate(raw_releases)
    ]
    builds = [release["build"] for release in releases]
    if len(builds) != len(set(builds)):
        raise ManifestInvalid("releases 中 build 重复")
    releases.sort(key=lambda item: (item["build"], item["published_at"]), reverse=True)
    return {
        "schema_version": schema_version,
        "channel": channel,
        "generated_at": generated_at,
        "releases": releases,
    }


_MANIFEST_CACHE: dict[str, tuple[int, int, dict[str, Any]]] = {}


def load_manifest(channel: str = DEFAULT_CHANNEL) -> dict[str, Any]:
    """读取并校验渠道清单（按 mtime/size 做进程内只读缓存）。

    缓存只保存**已通过完整校验**的归一化结果；文件一旦变化（mtime 或大小）
    立即重新读取。缓存绝不掩盖损坏：重新读取后仍按同一 fail-closed 规则处理。
    """
    channel = validate_channel(channel)
    path = manifest_path(channel)
    try:
        stat = path.stat()
    except FileNotFoundError as exc:
        _MANIFEST_CACHE.pop(str(path), None)
        raise ManifestUnavailable(f"manifest missing for channel {channel}") from exc
    except OSError as exc:
        _MANIFEST_CACHE.pop(str(path), None)
        raise ManifestUnavailable(f"manifest unreadable for channel {channel}") from exc
    cache_key = str(path)
    cached = _MANIFEST_CACHE.get(cache_key)
    if cached is not None and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
        return cached[2]
    max_bytes = int(getattr(settings, "AYLA_RELEASES_MAX_MANIFEST_BYTES", MAX_MANIFEST_BYTES))
    if stat.st_size <= 0:
        raise ManifestInvalid("manifest 为空")
    if stat.st_size > max_bytes:
        raise ManifestInvalid("manifest 超过大小上限")
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
    except OSError as exc:
        raise ManifestUnavailable("manifest 读取失败") from exc
    except UnicodeDecodeError as exc:
        raise ManifestInvalid("manifest 不是 UTF-8") from exc
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ManifestInvalid("manifest 不是合法 JSON") from exc
    manifest = validate_manifest(data, expected_channel=channel)
    _MANIFEST_CACHE[cache_key] = (stat.st_mtime_ns, stat.st_size, manifest)
    return manifest


def _artifact_matches(artifact: dict[str, Any], *, platform: str, arch: str) -> bool:
    if artifact["platform"] != platform:
        return False
    artifact_arch = artifact["arch"]
    if arch and artifact_arch == arch:
        return True
    if artifact_arch in UNIVERSAL_ARCHES:
        return True
    return not arch  # 未声明 arch 的客户端允许匹配该平台第一条


def select_latest(
    manifest: dict[str, Any], *, platform: str, arch: str = ""
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """选出该平台/架构可用的最高 build（不论当前客户端版本）。"""
    platform = validate_platform(platform)
    arch = validate_arch(arch)
    for release in manifest["releases"]:
        for artifact in release["artifacts"]:
            if _artifact_matches(artifact, platform=platform, arch=arch):
                return release, artifact
        # 该 release 没有此平台产物：继续找更早的 release，而不是直接宣告无更新
    return None


def public_download_url(path: str) -> str:
    base = str(getattr(settings, "AYLA_RELEASES_PUBLIC_BASE", "/releases")).rstrip("/")
    return f"{base}/{quote(path, safe='/+@')}"


def build_check_response(
    *,
    channel: str,
    platform: str,
    arch: str,
    current_version: str,
    current_build: int,
) -> dict[str, Any]:
    """构造 ``GET /updates/check/`` 响应（不包含文件系统路径）。"""
    channel = validate_channel(channel)
    platform = validate_platform(platform)
    arch = validate_arch(arch)
    base: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "channel": channel,
        "platform": platform,
        "arch": arch,
        "current": {"version": current_version, "build": current_build},
        "update_available": False,
        "mandatory": False,
        "degraded": False,
        "reason": "",
        "latest": None,
        "download": None,
    }
    try:
        manifest = load_manifest(channel)
    except ManifestUnavailable:
        logger.warning("release manifest unavailable: channel=%s", channel)
        base.update({"degraded": True, "reason": "manifest_unavailable"})
        return base
    except ManifestInvalid:
        logger.exception("release manifest invalid: channel=%s", channel)
        raise

    selected = select_latest(manifest, platform=platform, arch=arch)
    if selected is None:
        base["reason"] = "no_release_for_platform"
        return base
    release, artifact = selected
    latest = {
        "release_id": release["release_id"],
        "version": release["version"],
        "build": release["build"],
        "published_at": release["published_at"],
        "notes": release["notes"],
        "min_supported_build": release["min_supported_build"],
    }
    base["latest"] = latest
    if release["build"] <= current_build:
        base["reason"] = "up_to_date"
        return base
    mandatory = bool(release["mandatory"]) or current_build < release["min_supported_build"]
    base.update(
        {
            "update_available": True,
            "mandatory": mandatory,
            "reason": "update_available",
            "download": {
                "kind": artifact["kind"],
                "url": public_download_url(artifact["path"]),
                "file_name": artifact["file_name"],
                "size": artifact["size"],
                "sha256": artifact["sha256"],
                "install_url": artifact["install_url"],
            },
        }
    )
    return base
