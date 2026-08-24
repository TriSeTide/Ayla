"""
对象存储同步薄封装（S3/MinIO 兼容，boto3）。

- `ObjectStorage`：抽象接口；`S3Storage`：boto3 实现；`FakeStorage`：内存实现供测试。
- `get_storage()`：按 settings 返回单例后端；测试用 override_settings 或 monkeypatch 注入 FakeStorage。
- key 规划（步骤文件 4.1）：
  - `tmp/{upload_id}`：未 complete 的临时对象；
  - `media/{kind}/{media_id}/original`：正式对象；
  - `media/{kind}/{media_id}/thumbnail`：缩略图派生产物；
  - `media/{kind}/{media_id}/waveform`：波形派生产物。
  只存对象存储 key，绝对路径/宿主机路径永不入库、永不外发。
"""
import io
import logging

from django.conf import settings

logger = logging.getLogger(__name__)

# 派生资源 key 后缀
KEY_ORIGINAL = "original"
KEY_THUMBNAIL = "thumbnail"
KEY_WAVEFORM = "waveform"


def _b64decode_safe(value):
    import base64

    try:
        return base64.b64decode(value)
    except Exception:
        return b""


class ObjectStorage:
    """MinIO/S3 兼容对象存储的同步薄封装接口。"""

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        raise NotImplementedError

    def put_stream(self, key: str, fileobj, content_type: str = "application/octet-stream") -> None:
        """流式写入：从 fileobj（支持 read() 的二进制对象）分块上传，避免整体进内存。"""
        raise NotImplementedError

    def download_to(self, key, fileobj) -> int:
        """把对象流式下载写入 fileobj（支持 write() 的二进制对象），返回字节数。

        大文件不整体读入内存；调用方基于本地临时文件做哈希/嗅探/再上传。
        """
        raise NotImplementedError

    def open_stream(self, key):
        """打开对象的只读流（支持 read(n) 的 file-like）；不存在抛 KeyError。

        供 HTTP 响应分块转发（StreamingHttpResponse），下载不整体进内存。
        """
        raise NotImplementedError

    def get(self, key: str) -> bytes:
        raise NotImplementedError

    def get_range(self, key: str, start: int, end: int) -> bytes:
        raise NotImplementedError

    def head(self, key: str) -> int:  # 返回 size
        raise NotImplementedError

    def exists(self, key: str) -> bool:
        raise NotImplementedError

    def delete(self, key: str) -> None:
        raise NotImplementedError


class S3Storage(ObjectStorage):
    """boto3 同步实现（MinIO 兼容，endpoint_url 指向本地 MinIO）。"""

    def __init__(self, endpoint_url=None, access_key=None, secret_key=None,
                 bucket=None, region=None, public=False):
        import boto3
        from botocore.client import Config

        self._bucket = bucket or settings.S3_BUCKET
        # 私密媒体：任何派生对象都不带 public-read
        self._extra_args = {} if public else {"ACL": "private"}
        self._client = boto3.client(
            "s3",
            endpoint_url=endpoint_url or settings.S3_ENDPOINT_URL,
            aws_access_key_id=access_key or settings.S3_ACCESS_KEY,
            aws_secret_access_key=secret_key or settings.S3_SECRET_KEY,
            region_name=region or settings.S3_REGION,
            config=Config(signature_version="s3v4"),
        )
        self._ensure_bucket()

    def _ensure_bucket(self):
        try:
            self._client.head_bucket(Bucket=self._bucket)
        except Exception:
            try:
                self._client.create_bucket(Bucket=self._bucket)
                logger.info("created s3 bucket %s", self._bucket)
            except Exception as exc:
                logger.warning("create bucket %s failed: %s", self._bucket, exc)

    def put(self, key, data, content_type="application/octet-stream"):
        self._client.put_object(
            Bucket=self._bucket, Key=key, Body=data,
            ContentType=content_type, **self._extra_args,
        )

    def put_stream(self, key, fileobj, content_type="application/octet-stream"):
        # upload_fileobj 分块流式上传（不整体读入内存）；fileobj 需支持 read()，
        # 超大文件不会把整个对象驻留在 boto3 内存中
        self._client.upload_fileobj(
            fileobj, self._bucket, key,
            ExtraArgs={"ContentType": content_type, **self._extra_args},
        )

    def download_to(self, key, fileobj) -> int:
        resp = self._client.get_object(Bucket=self._bucket, Key=key)
        total = 0
        try:
            for chunk in resp["Body"].iter_chunks(chunk_size=1024 * 1024):
                fileobj.write(chunk)
                total += len(chunk)
        finally:
            resp["Body"].close()
        return total

    def open_stream(self, key):
        # S3 StreamingBody：支持 read(n) 分块读取；调用方负责 close
        resp = self._client.get_object(Bucket=self._bucket, Key=key)
        return resp["Body"]

    def open_range_stream(self, key, range_header):
        """按 HTTP Range 头打开对象的分块流（原样透传给对象存储）。

        支持 bytes=start-end / bytes=start- / bytes=-suffix 全部形态；
        返回 (streaming_body, content_length, content_range)。非法区间由
        对象存储返回错误，调用方映射为 416。
        """
        resp = self._client.get_object(Bucket=self._bucket, Key=key, Range=range_header)
        return (
            resp["Body"],
            int(resp["ContentLength"]),
            resp.get("ContentRange", ""),
        )

    def get(self, key):
        resp = self._client.get_object(Bucket=self._bucket, Key=key)
        return resp["Body"].read()

    def get_range(self, key, start, end):
        resp = self._client.get_object(
            Bucket=self._bucket, Key=key, Range=f"bytes={start}-{end}"
        )
        return resp["Body"].read()

    def head(self, key):
        resp = self._client.head_object(Bucket=self._bucket, Key=key)
        return resp["ContentLength"]

    def stat(self, key):
        """返回对象元信息 {"size", "etag", "content_type"}；不存在抛 ClientError。"""
        resp = self._client.head_object(Bucket=self._bucket, Key=key)
        etag = (resp.get("ETag") or "").strip('"')
        return {
            "size": resp["ContentLength"],
            "etag": etag,
            "content_type": resp.get("ContentType", ""),
        }

    def copy(self, src_key, dst_key, content_type="application/octet-stream"):
        """服务端对象复制（数据不经过应用服务器）。"""
        self._client.copy_object(
            Bucket=self._bucket, Key=dst_key,
            CopySource={"Bucket": self._bucket, "Key": src_key},
            ContentType=content_type, **self._extra_args,
        )

    def presign_put(self, key, content_type, expires_seconds):
        """生成直传用的预签名 PUT URL（浏览器绕过应用服务器直传对象存储）。

        注意：签名参数只含 Bucket/Key/ContentType——任何进入签名的额外头
        （如 ACL→x-amz-acl）都要求直传请求原样携带该头，浏览器侧容易遗漏，
        触发 S3 "headers present in the request which were not signed" 400。
        """
        return self._client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self._bucket, "Key": key,
                "ContentType": content_type,
            },
            ExpiresIn=expires_seconds,
        )

    def presign_get(self, key, expires_seconds):
        """生成播放/下载用的预签名 GET URL。

        <img>/<video> 直连对象存储后，Range 请求（preload=metadata、拖动 seek）
        由对象存储原生处理——播放流量完全不经过应用服务器（与直传对称，
        应用服务器只承担信令与鉴权决策）。
        """
        return self._client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=expires_seconds,
        )

    def exists(self, key):
        try:
            self.head(key)
            return True
        except Exception:
            return False

    def delete(self, key):
        try:
            self._client.delete_object(Bucket=self._bucket, Key=key)
        except Exception as exc:
            logger.warning("delete %s failed: %s", key, exc)


class FakeStorage(ObjectStorage):
    """内存字典实现，供测试注入，不依赖真实 MinIO。"""

    def __init__(self):
        self._data = {}
        self._meta = {}  # key -> {"content_type": str}

    def put(self, key, data, content_type="application/octet-stream"):
        self._data[key] = data
        self._meta[key] = {"content_type": content_type}

    def put_stream(self, key, fileobj, content_type="application/octet-stream"):
        fileobj.seek(0)
        self._data[key] = fileobj.read()
        self._meta[key] = {"content_type": content_type}

    def download_to(self, key, fileobj) -> int:
        data = self.get(key)
        fileobj.write(data)
        return len(data)

    def open_stream(self, key):
        return io.BytesIO(self.get(key))

    def open_range_stream(self, key, range_header):
        data = self.get(key)
        spec = range_header.removeprefix("bytes=").strip()
        if "-" not in spec:
            raise ValueError(f"invalid range: {range_header!r}")
        start_s, end_s = spec.split("-", 1)
        if start_s:
            start = int(start_s)
            end = int(end_s) if end_s else len(data) - 1
            if start < 0 or start > end or end >= len(data):
                raise ValueError(f"range out of bounds: {range_header!r}")
            chunk = data[start : end + 1]
            content_range = f"bytes {start}-{end}/{len(data)}"
        else:
            n = int(end_s) if end_s else 0
            if n <= 0 or n > len(data):
                raise ValueError(f"invalid suffix range: {range_header!r}")
            chunk = data[-n:]
            content_range = f"bytes {len(data)-n}-{len(data)-1}/{len(data)}"
        body = io.BytesIO(chunk)
        return body, len(chunk), content_range

    def get(self, key):
        if key not in self._data:
            raise KeyError(key)
        return self._data[key]

    def get_range(self, key, start, end):
        data = self.get(key)
        return data[start : end + 1]  # 含 end（HTTP Range 闭区间语义）

    def head(self, key):
        return len(self.get(key))

    def stat(self, key):
        data = self.get(key)
        return {
            "size": len(data),
            "etag": __import__("hashlib").md5(data).hexdigest(),
            "content_type": self._meta.get(key, {}).get("content_type", ""),
        }

    def copy(self, src_key, dst_key, content_type="application/octet-stream"):
        data = self.get(src_key)
        meta = self._meta.get(src_key, {}).get("content_type", content_type)
        self._data[dst_key] = data
        self._meta[dst_key] = {"content_type": meta}

    def presign_put(self, key, content_type, expires_seconds):
        # 测试环境无真实对象存储：返回可识别的伪 URL（契约测试只断言形态）
        from urllib.parse import quote

        return f"http://fake-storage/{quote(key)}?X-Amz-Expires={expires_seconds}&ct={quote(content_type)}"

    def presign_get(self, key, expires_seconds):
        from urllib.parse import quote

        return f"http://fake-storage/{quote(key)}?X-Amz-Expires={expires_seconds}&mode=get"

    def exists(self, key):
        return key in self._data

    def delete(self, key):
        self._data.pop(key, None)
        self._meta.pop(key, None)


_instance = None


def get_storage() -> ObjectStorage:
    """按 settings 返回单例存储后端。测试注入 FakeStorage 用 override_settings 或 monkeypatch。"""
    global _instance
    storage_backend = getattr(settings, "S3_STORAGE_BACKEND", "s3")
    if storage_backend == "fake":
        if _instance is None or not isinstance(_instance, FakeStorage):
            _instance = FakeStorage()
        return _instance
    if _instance is None or not isinstance(_instance, S3Storage):
        _instance = S3Storage()
    return _instance


def reset_storage_cache() -> None:
    """清空单例（测试隔离用）。"""
    global _instance
    _instance = None


def original_key(kind: str, media_id: str) -> str:
    return f"media/{kind}/{media_id}/{KEY_ORIGINAL}"


def thumbnail_key(kind: str, media_id: str) -> str:
    return f"media/{kind}/{media_id}/{KEY_THUMBNAIL}"


def waveform_key(kind: str, media_id: str) -> str:
    return f"media/{kind}/{media_id}/{KEY_WAVEFORM}"


def tmp_key(upload_id: str) -> str:
    return f"tmp/{upload_id}"
