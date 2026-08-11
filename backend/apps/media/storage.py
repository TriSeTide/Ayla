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

    def get(self, key):
        if key not in self._data:
            raise KeyError(key)
        return self._data[key]

    def get_range(self, key, start, end):
        data = self.get(key)
        return data[start : end + 1]  # 含 end（HTTP Range 闭区间语义）

    def head(self, key):
        return len(self.get(key))

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
