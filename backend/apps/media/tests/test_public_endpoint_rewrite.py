"""预签名 URL 的对外基址改写（S3_PUBLIC_ENDPOINT）契约测试（2026-10-27）。

## 为什么需要
用户实报「手机端上传的图片在 web 不显示」。排查链：
- 媒体走**预签名直连**（/media/<id>:sign -> 对象存储 URL），不经过应用服务器；
- presign_get 生成的 URL 带的是 S3_ENDPOINT_URL 的 host —— 那是**服务端内部**
  地址（http://127.0.0.1:9000）；
- 浏览器拿到的就是 http://127.0.0.1:9000/... ⇒ **根本连不上** ⇒ 图片白板。

修法：配置 S3_PUBLIC_ENDPOINT（浏览器可达的同源前缀，如 https://host/minio），
签发时把 scheme://host 替换掉；**query 里的签名串不动**。
"""
from __future__ import annotations

from django.test import override_settings

from apps.media.storage import _rewrite_to_public_endpoint

INTERNAL = (
    "http://127.0.0.1:9000/elysia-media/media/image/abc/original"
    "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=k%2F20261027"
    "&X-Amz-Signature=deadbeef"
)


def test_rewrites_host_to_public_endpoint():
    """★ 内网 host 必须被替换成公网可达前缀。"""
    with override_settings(S3_PUBLIC_ENDPOINT="https://s.ayla.trise.top:26211/minio"):
        out = _rewrite_to_public_endpoint(INTERNAL)
    assert out.startswith("https://s.ayla.trise.top:26211/minio/elysia-media/")
    assert "127.0.0.1" not in out, "★ 内网地址绝不能出现在给浏览器的 URL 里"


def test_signature_query_is_preserved():
    """★ 签名 query 必须原样保留（改了会 403）。"""
    with override_settings(S3_PUBLIC_ENDPOINT="https://s.ayla.trise.top:26211/minio"):
        out = _rewrite_to_public_endpoint(INTERNAL)
    assert "X-Amz-Signature=deadbeef" in out
    assert "X-Amz-Algorithm=AWS4-HMAC-SHA256" in out


def test_no_config_keeps_original():
    """未配置时原样返回（本地开发直连 MinIO 不受影响）。"""
    with override_settings(S3_PUBLIC_ENDPOINT=""):
        assert _rewrite_to_public_endpoint(INTERNAL) == INTERNAL
