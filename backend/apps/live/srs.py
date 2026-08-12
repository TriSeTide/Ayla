"""
SRS 客户端（M4-6 §4）—— SRS HTTP API 同步薄封装（状态查询），可注入 fake 供测试。

- `SrsClient`：GET `/api/v1/streams` 查询活跃流，短超时；查询失败抛 ``SrsUnavailable``
  （**绝不把查询失败当"未在播"**，AGENTS.md §8：错误恢复不得把失败伪装成空结果）；
- `FakeSrsClient`：内存实现，测试注入（`set_streams(...)` 模拟在播/不在播，`set_fail(...)` 模拟 SRS 不可用）；
- `get_srs()`：按 settings 返回单例；测试通过 monkeypatch 覆盖为 FakeSrsClient。

状态判定语义（M4-6 §4.2）：
- 应用侧 `LiveChannel.status` 是乐观标记（:start/:stop 更新）；
- **"是否在播"以 `srs.is_streaming("live", stream_key)` 实时判定为准**；
- SRS 查询失败（超时/网络/非 200）→ 上层返回 `{"status": "degraded", "detail": "srs_unavailable"}`，
  禁止伪装成"未在播"。
"""
import logging
from typing import Any

from django.conf import settings

logger = logging.getLogger(__name__)

SRS_STREAMS_PATH = "/api/v1/streams"
SRS_VERSIONS_PATH = "/api/v1/versions"


class SrsUnavailable(RuntimeError):
    """SRS 查询失败（超时/网络/非 200/响应结构异常）。"""


class SrsClient:
    """SRS HTTP API 同步薄封装（查询流状态，短超时，不阻塞事件循环时在同步线程调用）。"""

    def __init__(self, api_url: str | None = None, timeout: float | None = None):
        self.api_url = (api_url or settings.SRS_API_URL).rstrip("/")
        self.timeout = timeout if timeout is not None else settings.SRS_QUERY_TIMEOUT

    def _get_json(self, path: str) -> dict[str, Any]:
        """GET {api_url}{path} → 解析 JSON；任何失败抛 SrsUnavailable。"""
        import httpx

        url = f"{self.api_url}{path}"
        try:
            resp = httpx.get(url, timeout=self.timeout)
        except httpx.HTTPError as exc:
            logger.warning("srs http error: url=%s err=%s", url, exc)
            raise SrsUnavailable(f"srs http error: {exc}") from exc
        if resp.status_code != 200:
            logger.warning(
                "srs http non-200: url=%s status=%s", url, resp.status_code
            )
            raise SrsUnavailable(f"srs http {resp.status_code}")
        try:
            return resp.json()
        except ValueError as exc:  # JSON 解析失败
            logger.warning("srs bad json: url=%s", url)
            raise SrsUnavailable(f"srs bad json: {exc}") from exc

    def list_streams(self) -> list[dict]:
        """GET /api/v1/streams → [{app, stream, ...}]；失败抛 SrsUnavailable。"""
        data = self._get_json(SRS_STREAMS_PATH)
        streams = data.get("streams")
        if streams is None or not isinstance(streams, list):
            logger.warning("srs streams payload unexpected: %r", data)
            raise SrsUnavailable("srs streams payload unexpected")
        return streams

    def is_streaming(self, app: str, stream: str) -> bool:
        """streams 中存在 app+stream 匹配即视为在播；查询失败抛 SrsUnavailable。"""
        for s in self.list_streams():
            if s.get("app") == app and s.get("stream") == stream:
                return True
        return False

    def health(self) -> str:
        """健康检查：GET /api/v1/versions → "ok" / "error"（不抛异常）。"""
        try:
            data = self._get_json(SRS_VERSIONS_PATH)
            return "ok" if data else "error"
        except SrsUnavailable:
            return "error"


class FakeSrsClient(SrsClient):
    """内存实现，测试注入；set_streams/set_fail 模拟在播/不在播/不可用。"""

    def __init__(
        self,
        streams: list[dict] | None = None,
        *,
        fail: bool = False,
        api_url: str = "http://srs-test.invalid:1985",
        timeout: float = 0.1,
    ):
        super().__init__(api_url=api_url, timeout=timeout)
        self._streams = [dict(s) for s in (streams or [])]
        self._fail = fail

    def set_streams(self, streams: list[dict]) -> None:
        """模拟活跃流列表（[{app, stream, ...}]）。"""
        self._streams = [dict(s) for s in streams]

    def set_fail(self, fail: bool) -> None:
        """模拟 SRS 不可用（True → 后续查询抛 SrsUnavailable）。"""
        self._fail = fail

    def list_streams(self) -> list[dict]:
        if self._fail:
            raise SrsUnavailable("fake srs unavailable")
        return [dict(s) for s in self._streams]

    def health(self) -> str:
        return "error" if self._fail else "ok"


_srs_singleton: SrsClient | None = None


def get_srs() -> SrsClient:
    """按 settings 返回单例；settings_test 覆盖为 FakeSrsClient（测试注入）。"""
    global _srs_singleton
    if _srs_singleton is None:
        _srs_singleton = SrsClient()
    return _srs_singleton
