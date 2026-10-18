#!/usr/bin/env python3
"""Ayla 客户端发布工具：构建 release、上传发布目录、原子更新 manifest、热更新后端。

子命令
------
build           本机构建 release（Windows zip / Android APK；macOS 可加 iOS）
publish         上传产物并把 manifest-<channel>.json 原子替换
deploy-backend  用 git bundle 更新服务器 Ayla 后端并重建/重启 backend 容器
all             build -> publish -> deploy-backend

环境变量
--------
AYLA_RELEASE_HOST   默认 ayerelysia（~/.ssh/config 别名）
AYLA_RELEASE_ROOT   默认 ~/Elysia/ayla-deploy/releases
AYLA_REMOTE_REPO    默认 ~/Elysia/Elysium/Ayla
AYLA_DEPLOY_DIR     默认 ~/Elysia/ayla-deploy
AYLA_API_BASE       默认 https://s.ayla.trise.top:26211
AYLA_UPDATE_CHANNEL 默认 stable
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLUTTER_DIR = ROOT / "flutter"
DIST_DIR = FLUTTER_DIR / "dist" / "release"
MANIFEST_VERSION = 1
DEFAULT_HOST = os.environ.get("AYLA_RELEASE_HOST", "ayerelysia")
DEFAULT_ROOT = os.environ.get("AYLA_RELEASE_ROOT", "~/Elysia/ayla-deploy/releases")
DEFAULT_REMOTE_REPO = os.environ.get("AYLA_REMOTE_REPO", "~/Elysia/Elysium/Ayla")
DEFAULT_DEPLOY_DIR = os.environ.get("AYLA_DEPLOY_DIR", "~/Elysia/ayla-deploy")
DEFAULT_API_BASE = os.environ.get("AYLA_API_BASE", "https://s.ayla.trise.top:26211")
DEFAULT_CHANNEL = os.environ.get("AYLA_UPDATE_CHANNEL", "stable")


class ReleaseError(RuntimeError):
    """可诊断的发布失败（不打印密钥）。"""


def run(cmd, *, cwd=None, capture=False):
    parts = [str(part) for part in cmd]
    # Windows：`flutter` 是 flutter.bat，subprocess 不带 shell 时无法直接执行 .bat
    # （CreateProcess 只解析 .exe）。这里按 PATH 解析真实可执行文件，避免要求调用方
    # 使用 shell（shell=True 会引入命令注入面且破坏参数转义）。
    if os.name == "nt" and parts and not Path(parts[0]).suffix:
        resolved = shutil.which(parts[0])
        if resolved:
            parts[0] = resolved
    print("+ " + " ".join(parts))
    result = subprocess.run(
        parts,
        cwd=str(cwd) if cwd else None,
        text=True,
        # Windows 控制台默认 GBK；Python 3.15 前 text=True 会按 locale 解码，遇到
        # UTF-8 的远端输出直接崩。显式固定 UTF-8 + replace，保证诊断信息不丢失。
        encoding="utf-8",
        errors="replace",
        capture_output=capture,
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseError(
            "命令失败（exit %s）：%s" % (result.returncode, " ".join(str(p) for p in cmd))
        )
    return result


def ssh(host, remote_command, *, capture=False):
    return run(["ssh", host, remote_command], capture=capture)


def scp(host, local, remote):
    run(["scp", str(local), f"{host}:{remote}"])


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_version(version, build):
    value = version.strip()
    if not value:
        raise ReleaseError("--version 不能为空")
    if "+" in value:
        value, _, build_text = value.partition("+")
        if build_text:
            build = int(build_text)
    if build <= 0:
        raise ReleaseError("--build 必须是正整数")
    return value, build


def read_notes(path):
    if not path:
        return ""
    text = Path(path).read_text(encoding="utf-8").strip()
    if len(text) > 8000:
        raise ReleaseError("发布说明超过 8000 字符")
    return text


def make_manifest_entry(channel, version, build, notes, mandatory, min_supported_build, artifacts):
    return {
        "release_id": f"{channel}-{version}-{build}",
        "version": version,
        "build": build,
        "published_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "notes": notes,
        "mandatory": mandatory,
        "min_supported_build": min_supported_build,
        "artifacts": artifacts,
    }


def validate_manifest(manifest, channel):
    """与后端 apps.releases.services 的核心约束一致（上传前自检）。"""
    if not isinstance(manifest, dict) or manifest.get("schema_version") != MANIFEST_VERSION:
        raise ReleaseError("manifest schema_version 不合法")
    if manifest.get("channel") != channel:
        raise ReleaseError("manifest channel 不一致")
    releases = manifest.get("releases")
    if not isinstance(releases, list) or not releases:
        raise ReleaseError("manifest releases 不能为空")
    builds = set()
    for release in releases:
        if not isinstance(release, dict):
            raise ReleaseError("manifest release 必须是对象")
        build = release.get("build")
        if not isinstance(build, int) or build <= 0:
            raise ReleaseError("release.build 不合法")
        if build in builds:
            raise ReleaseError("release.build 重复：%s" % build)
        builds.add(build)
        for artifact in release.get("artifacts", []):
            path = artifact.get("path", "")
            parts = path.split("/")
            if not path.startswith(channel + "/") or ".." in parts:
                raise ReleaseError("artifact.path 不合法：%s" % path)
            sha = artifact.get("sha256")
            if not isinstance(sha, str) or len(sha) != 64:
                raise ReleaseError("artifact.sha256 不合法")
            if not isinstance(artifact.get("size"), int) or artifact["size"] <= 0:
                raise ReleaseError("artifact.size 不合法")


def build_flutter(api_base, version, build, platforms, channel):
    """构建指定平台；产物复制到 dist/release/<version>+<build>/。"""
    if not (FLUTTER_DIR / "pubspec.yaml").exists():
        raise ReleaseError("找不到 Flutter 工程：%s" % FLUTTER_DIR)
    out_dir = DIST_DIR / f"{version}+{build}"
    out_dir.mkdir(parents=True, exist_ok=True)
    built = {}
    defines = [
        f"--dart-define=AYLA_API_BASE={api_base}",
        f"--dart-define=AYLA_UPDATE_CHANNEL={channel}",
    ]
    version_args = [f"--build-name={version}", f"--build-number={build}"]
    for target in platforms:
        if target == "windows":
            run(["flutter", "build", "windows", "--release", *version_args, *defines], cwd=FLUTTER_DIR)
            source = FLUTTER_DIR / "build" / "windows" / "x64" / "runner" / "Release"
            if not source.is_dir():
                raise ReleaseError("Windows release 目录不存在")
            archive = out_dir / f"ayla-windows-x64-{version}+{build}.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
                for file in sorted(source.rglob("*")):
                    if file.is_file():
                        bundle.write(file, file.relative_to(source).as_posix())
            built["windows"] = archive
            print("[build] Windows -> %s (%s bytes)" % (archive, archive.stat().st_size))
        elif target == "android":
            # Flutter 3.47 要求 Gradle >= 8.14，本工程 wrapper 仍为 8.12（升级需整体回归
            # AGP/Kotlin，属独立任务）⇒ 显式跳过版本校验；构建成功与否仍由 Gradle 真实结果决定。
            run(
                [
                    "flutter",
                    "build",
                    "apk",
                    "--release",
                    "--android-skip-build-dependency-validation",
                    *version_args,
                    *defines,
                ],
                cwd=FLUTTER_DIR,
            )
            apk = FLUTTER_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
            if not apk.is_file():
                raise ReleaseError("Android release APK 不存在")
            apk_file = out_dir / f"ayla-android-universal-{version}+{build}.apk"
            shutil.copy2(apk, apk_file)
            built["android"] = apk_file
            print("[build] Android -> %s (%s bytes)" % (apk_file, apk_file.stat().st_size))
        elif target == "ios":
            if platform.system() != "Darwin":
                raise ReleaseError("iOS 构建只能在 macOS 上执行")
            run(["flutter", "build", "ipa", "--release", *version_args, *defines], cwd=FLUTTER_DIR)
            ipa_dir = FLUTTER_DIR / "build" / "ios" / "ipa"
            candidates = list(ipa_dir.glob("*.ipa"))
            if not candidates:
                raise ReleaseError("iOS IPA 不存在")
            ipa_file = out_dir / f"ayla-ios-{version}+{build}.ipa"
            shutil.copy2(candidates[0], ipa_file)
            built["ios"] = ipa_file
            print("[build] iOS -> %s" % ipa_file)
        else:
            raise ReleaseError("不支持的平台：%s" % target)
    return built


def artifact_entries(channel, version, build, built, artifacts_dir):
    specs = (
        ("windows", "x64", "zip"),
        ("android", "universal", "apk"),
        ("ios", "universal", "ipa"),
    )
    artifacts = []
    for target, arch, kind in specs:
        path = built.get(target)
        if path is None and artifacts_dir is not None:
            candidates = sorted(artifacts_dir.glob("ayla-%s-*" % target))
            if candidates:
                path = candidates[0]
        if path is None:
            continue
        artifacts.append(
            {
                "platform": target,
                "arch": arch,
                "kind": kind,
                "path": "%s/%s/%s+%s/%s" % (channel, target, version, build, path.name),
                "file_name": path.name,
                "size": path.stat().st_size,
                "sha256": sha256_file(path),
                "install_url": None,
            }
        )
    return artifacts


def fetch_remote_manifest(host, remote_root, channel):
    remote_manifest = f"{remote_root}/manifest-{channel}.json"
    remote_manifest = f"{remote_root}/manifest-{channel}.json"
    # 注意：`ssh` / `run` 对非 0 退出码会抛 ReleaseError（这是其余命令需要的 fail-fast）。
    # “manifest 尚不存在”是合法初态，必须显式走 subprocess 探测，不能借用 ssh()。
    probe = subprocess.run(
        ["ssh", host, f"test -f {remote_manifest}"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if probe.returncode != 0:
        return {
            "schema_version": MANIFEST_VERSION,
            "channel": channel,
            "generated_at": "",
            "releases": [],
        }
    result = ssh(host, f"cat {remote_manifest}", capture=True)
    if not result.stdout.strip():
        return {
            "schema_version": MANIFEST_VERSION,
            "channel": channel,
            "generated_at": "",
            "releases": [],
        }
    try:
        manifest = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ReleaseError("服务器现有 manifest 不是合法 JSON：%s" % exc)
    validate_manifest(manifest, channel)
    return manifest


def publish(host, remote_root, channel, version, build, notes, mandatory,
            min_supported_build, artifacts, artifacts_dir, allow_replace):
    manifest = fetch_remote_manifest(host, remote_root, channel)
    existing = [r for r in manifest["releases"] if r.get("build") == build]
    if existing and not allow_replace:
        raise ReleaseError("release build %s 已存在；覆盖请显式加 --allow-replace" % build)
    release = make_manifest_entry(
        channel, version, build, notes, mandatory, min_supported_build, artifacts
    )
    releases = [r for r in manifest["releases"] if r.get("build") != build]
    releases.append(release)
    releases.sort(key=lambda r: (r["build"], r.get("published_at", "")), reverse=True)
    manifest = {
        "schema_version": MANIFEST_VERSION,
        "channel": channel,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "releases": releases,
    }
    validate_manifest(manifest, channel)

    for artifact in artifacts:
        local = DIST_DIR / f"{version}+{build}" / artifact["file_name"]
        if not local.is_file() and artifacts_dir is not None:
            local = artifacts_dir / artifact["file_name"]
        if not local.is_file():
            raise ReleaseError("找不到本地产物：%s" % artifact["file_name"])
        remote_dir = f"{remote_root}/{Path(artifact['path']).parent.as_posix()}"
        ssh(host, f"mkdir -p {remote_dir}")
        scp(host, local, f"{remote_dir}/{artifact['file_name']}.tmp")
        ssh(host, f"mv -f {remote_dir}/{artifact['file_name']}.tmp {remote_dir}/{artifact['file_name']}")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".json") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        local_manifest = Path(handle.name)
    try:
        remote_manifest_tmp = f"{remote_root}/manifest-{channel}.json.tmp"
        scp(host, local_manifest, remote_manifest_tmp)
        ssh(host, f"mv -f {remote_manifest_tmp} {remote_root}/manifest-{channel}.json")
    finally:
        local_manifest.unlink(missing_ok=True)
    print("[publish] %s -> %s/manifest-%s.json" % (release["release_id"], remote_root, channel))


def _resolve_local_repo():
    """确定要发布的本地仓库：优先 Ayla 子模块，否则当前目录（独立 clone）。"""
    candidate = ROOT / "Ayla"
    if (candidate / ".git").exists():
        return candidate
    return ROOT


def deploy_backend(host, remote_repo, deploy_dir):
    """用 git bundle 把本地 Ayla 后端源码快进到服务器并重建镜像。

    服务器 `~/Elysia/Elysium/Ayla` 是 Ayla 子模块工作树；父仓库 Elysium 在服务器上
    有独立未提交修改且与线上分叉，因此本命令只更新 **Ayla 后端仓库**（后端镜像的
    build context 就是该目录），不改父仓库指针，避免破坏服务器上正在运行的 Elysium。
    """
    repo_dir = _resolve_local_repo()
    local_head = run(["git", "rev-parse", "HEAD"], cwd=repo_dir, capture=True).stdout.strip()
    remote_head = ssh(host, f"cd {remote_repo} && git rev-parse HEAD", capture=True).stdout.strip()
    if not remote_head:
        raise ReleaseError("无法读取服务器 Ayla HEAD")
    if local_head == remote_head:
        print("[deploy-backend] 服务器已是最新 Ayla 提交")
    else:
        ancestor = subprocess.run(
            ["git", "merge-base", "--is-ancestor", remote_head, local_head],
            cwd=str(repo_dir),
            check=False,
        ).returncode == 0
        if not ancestor:
            raise ReleaseError("服务器 Ayla 与本地不是快进关系；拒绝覆盖，请人工合并")
        bundle_path = Path(tempfile.gettempdir()) / ("ayla-backend-%s.bundle" % local_head[:10])
        remote_bundle = "/tmp/%s" % bundle_path.name
        # ⚠️ `A..B`（两个 40 位 sha）在部分 Git for Windows 版本会被判成
        # “empty bundle”（实测 2.56.0.windows.2 复现；`A..HEAD` 正常）。
        # 先建临时 ref 指向远端 HEAD，再用 `refs/.../base..HEAD` 表达同一区间。
        base_ref = "refs/ayla-publish/base"
        run(["git", "update-ref", base_ref, remote_head], cwd=repo_dir)
        try:
            run(["git", "bundle", "create", str(bundle_path), f"{base_ref}..HEAD"], cwd=repo_dir)
            scp(host, bundle_path, remote_bundle)
            remote_script = "\n".join(
                [
                    "set -euo pipefail",
                    "cd %s" % remote_repo,
                    "git bundle verify %s" % remote_bundle,
                    "git fetch %s %s:refs/ayla/incoming" % (remote_bundle, local_head),
                    "git merge --ff-only refs/ayla/incoming",
                    "git log -1 --oneline",
                ]
            )
            ssh(host, remote_script)
        finally:
            bundle_path.unlink(missing_ok=True)
            subprocess.run(
                ["git", "update-ref", "-d", base_ref],
                cwd=str(repo_dir),
                check=False,
            )
    rebuild = "\n".join(
        [
            "set -euo pipefail",
            "cd %s" % deploy_dir,
            # 线上 Docker daemon 配置了 HTTP 代理 127.0.0.1:7890；代理未运行时
            # docker build 拉不到基础镜像，容器内 pip 也没有网络。用已有镜像作基础
            # （BASE_IMAGE 构建参数）+ host 网络让 pip 走宿主机，是实测可用的离线路径。
            "docker build --network=host --build-arg BASE_IMAGE=ayla-backend:pre-20260916 "
            "-f %s/backend/Dockerfile -t ayla-backend:latest %s/backend" % (remote_repo, remote_repo),
            "docker compose up -d --no-deps backend",
            "sleep 5",
            "docker ps --filter name=ayla-backend --format '{{.Names}} {{.Status}}'",
        ]
    )
    ssh(host, rebuild)
    print("[deploy-backend] 后端已重建并重启")


def parse_platforms(value):
    platforms = [item.strip().lower() for item in value.split(",") if item.strip()]
    if not platforms:
        raise ReleaseError("--platforms 不能为空")
    for item in platforms:
        if item not in {"windows", "android", "ios"}:
            raise ReleaseError("不支持的平台：%s" % item)
    return platforms


def main(argv=None):
    parser = argparse.ArgumentParser(description="Ayla 客户端发布工具")
    parser.add_argument("command", choices=["build", "publish", "deploy-backend", "all"])
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--remote-root", default=DEFAULT_ROOT)
    parser.add_argument("--remote-repo", default=DEFAULT_REMOTE_REPO)
    parser.add_argument("--deploy-dir", default=DEFAULT_DEPLOY_DIR)
    parser.add_argument("--channel", default=DEFAULT_CHANNEL)
    parser.add_argument("--version", default="")
    parser.add_argument("--build", type=int, default=0)
    parser.add_argument("--notes-file", default="")
    parser.add_argument("--mandatory", action="store_true")
    parser.add_argument("--min-supported-build", type=int, default=0)
    parser.add_argument("--platforms", default="windows,android")
    parser.add_argument("--api-base", default=DEFAULT_API_BASE)
    parser.add_argument("--allow-replace", action="store_true")
    parser.add_argument("--artifacts-dir", default="")
    args = parser.parse_args(argv)

    try:
        if args.command != "deploy-backend" and (not args.version or args.build <= 0):
            raise ReleaseError("该命令需要 --version 与 --build")
        version, build = normalize_version(args.version, args.build) if args.version else ("", 0)
        built = {}
        if args.command in {"build", "all"}:
            built = build_flutter(
                args.api_base, version, build, parse_platforms(args.platforms), args.channel
            )
        if args.command in {"publish", "all"}:
            artifacts_dir = Path(args.artifacts_dir) if args.artifacts_dir else None
            artifacts = artifact_entries(args.channel, version, build, built, artifacts_dir)
            if not artifacts:
                raise ReleaseError("没有可发布的产物")
            publish(
                args.host,
                args.remote_root,
                args.channel,
                version,
                build,
                read_notes(args.notes_file),
                args.mandatory,
                args.min_supported_build,
                artifacts,
                artifacts_dir,
                args.allow_replace,
            )
        if args.command in {"deploy-backend", "all"}:
            deploy_backend(args.host, args.remote_repo, args.deploy_dir)
        return 0
    except ReleaseError as exc:
        print("发布失败：%s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
