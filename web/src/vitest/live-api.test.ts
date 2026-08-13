/**
 * api/live.ts 契约测试（M5-4 文档 §7.1）：
 * - 列表/详情字段对齐；only_live=1 过滤参数正确
 * - 非 owner 详情 stream_key=null 正常处理
 * - :start/:stop 403、删除 400 的 detail 透传
 * - /status/ 三态（live/idle/degraded）结构对齐
 * - 弹幕 POST 400 detail；GET 历史裸数组
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Mock } from "vitest";
import {
  createLiveChannel,
  deleteLiveChannel,
  getLiveChannel,
  getLiveChannelStatus,
  listDanmaku,
  listLiveChannels,
  sendDanmaku,
  startLiveChannel,
  stopLiveChannel,
} from "../api/live";
import { ApiError } from "../api/client";
import { useAuthStore } from "../stores/auth";
import { useLiveStore } from "../stores/live";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function mockFetchOnce(body: unknown, status = 200) {
  (fetch as Mock).mockResolvedValueOnce(jsonResponse(body, status));
}

function lastFetchUrl(): string {
  const calls = (fetch as Mock).mock.calls;
  return String(calls[calls.length - 1][0]);
}

const OWNER_CHANNEL = {
  id: 7,
  title: "爱莉的午后",
  status: "idle",
  owner_id: "u-owner",
  is_owner: true,
  stream_key: "abc123key",
  rtmp_url: "rtmp://127.0.0.1:1935/live/abc123key",
  hls_url: "http://127.0.0.1:8080/live/abc123key.m3u8",
  flv_url: "http://127.0.0.1:8080/live/abc123key.flv",
  started_at: null,
  ended_at: null,
  created_at: "2026-08-13T00:00:00+08:00",
};

beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn());
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
  useLiveStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
  useLiveStore.getState().reset();
});

describe("live api", () => {
  it("listLiveChannels：默认无 query；onlyLive=true 带 ?only_live=1", async () => {
    mockFetchOnce([OWNER_CHANNEL]);
    const list = await listLiveChannels();
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/");
    expect(list).toHaveLength(1);
    expect(list[0].id).toBe(7);

    mockFetchOnce([]);
    await listLiveChannels(true);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/?only_live=1");
  });

  it("createLiveChannel：POST {title} → 201 回显 stream_key/rtmp_url", async () => {
    mockFetchOnce(OWNER_CHANNEL, 201);
    const ch = await createLiveChannel("爱莉的午后");
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/");
    const body = JSON.parse(
      String((fetch as Mock).mock.calls[0][1]?.body),
    ) as Record<string, unknown>;
    expect(body).toEqual({ title: "爱莉的午后" });
    expect(ch.stream_key).toBe("abc123key");
    expect(ch.rtmp_url).toBe("rtmp://127.0.0.1:1935/live/abc123key");
  });

  it("getLiveChannel：非 owner 详情 stream_key/rtmp_url 为 null 是正常契约", async () => {
    mockFetchOnce({
      ...OWNER_CHANNEL,
      is_owner: false,
      stream_key: null,
      rtmp_url: null,
    });
    const ch = await getLiveChannel(7);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7/");
    expect(ch.is_owner).toBe(false);
    expect(ch.stream_key).toBeNull();
    expect(ch.rtmp_url).toBeNull();
    // hls_url / flv_url 全员可见
    expect(ch.hls_url).toContain(".m3u8");
    expect(ch.flv_url).toContain(".flv");
  });

  it("startLiveChannel / stopLiveChannel：冒号 action 路径正确", async () => {
    mockFetchOnce({ ...OWNER_CHANNEL, status: "live" });
    const started = await startLiveChannel(7);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7:start/");
    expect(started.status).toBe("live");

    mockFetchOnce({ ...OWNER_CHANNEL, status: "ended" });
    const stopped = await stopLiveChannel(7);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7:stop/");
    expect(stopped.status).toBe("ended");
  });

  it("startLiveChannel：非 owner 403 → ApiError 透传 detail", async () => {
    mockFetchOnce({ detail: "仅频道 owner 可开播" }, 403);
    await expect(startLiveChannel(7)).rejects.toMatchObject({
      status: 403,
      message: "仅频道 owner 可开播",
    });
  });

  it("deleteLiveChannel：直播中删除 400 → detail 提示先下播", async () => {
    mockFetchOnce({ detail: "直播中禁止删除，请先 :stop" }, 400);
    await expect(deleteLiveChannel(7)).rejects.toMatchObject({
      status: 400,
      message: "直播中禁止删除，请先 :stop",
    });
  });

  it("getLiveChannelStatus：三态结构（live/idle/degraded）", async () => {
    mockFetchOnce({ status: "live", source: "srs", detail: null, optimistic: "live" });
    const live = await getLiveChannelStatus(7);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7/status/");
    expect(live.status).toBe("live");

    mockFetchOnce({ status: "idle", source: "srs", detail: null, optimistic: "live" });
    expect((await getLiveChannelStatus(7)).status).toBe("idle");

    // degraded = SRS 不可用，不是未在播
    mockFetchOnce({
      status: "degraded",
      source: "srs_unavailable",
      detail: "srs_unavailable",
      optimistic: "idle",
    });
    const degraded = await getLiveChannelStatus(7);
    expect(degraded.status).toBe("degraded");
    expect(degraded.source).toBe("srs_unavailable");
  });

  it("sendDanmaku：POST {content} → 201；超长 400 detail 透传", async () => {
    const item = {
      id: "12",
      channel_id: "7",
      sender: { user_id: "u1", nickname: "汐汐", avatar: "" },
      content: "来了",
      created_at: "2026-08-13T00:00:00Z",
    };
    mockFetchOnce(item, 201);
    const sent = await sendDanmaku(7, "来了");
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7/danmaku/");
    expect(sent.id).toBe("12");
    expect(sent.sender.nickname).toBe("汐汐");

    mockFetchOnce({ detail: "content 长度不能超过 200" }, 400);
    await expect(sendDanmaku(7, "x".repeat(201))).rejects.toMatchObject({
      status: 400,
      message: "content 长度不能超过 200",
    });
    // ApiError 实例
    mockFetchOnce({ detail: "content 不能为空" }, 400);
    await expect(sendDanmaku(7, " ")).rejects.toBeInstanceOf(ApiError);
  });

  it("listDanmaku：GET 历史裸数组、limit 参数正确", async () => {
    mockFetchOnce([
      {
        id: "1",
        sender: { user_id: "u1", nickname: "a", avatar: "" },
        content: "早",
        created_at: "2026-08-13T00:00:00Z",
      },
      {
        id: "2",
        sender: { user_id: "u2", nickname: "b", avatar: "" },
        content: "来了",
        created_at: "2026-08-13T00:01:00Z",
      },
    ]);
    const list = await listDanmaku(7, 50);
    expect(lastFetchUrl()).toBe("/api/v1/live/channels/7/danmaku/?limit=50");
    expect(Array.isArray(list)).toBe(true);
    expect(list).toHaveLength(2);
    // 升序
    expect(list[0].created_at < list[1].created_at).toBe(true);
  });
});
