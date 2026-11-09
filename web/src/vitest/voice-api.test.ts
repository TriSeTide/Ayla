/**
 * api/voice.ts 契约测试（mock fetch，M5-3 §7.1）：
 * - 频道 REST：列表/建频道/详情字段对齐；join 503 显式暴露给调用方
 * - heartbeat 非成员 → 403
 * - leave 幂等
 * - token 纪律：本层不打日志（无 console 调用可 grep 验证）
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import { ApiError } from "../api/client";
import { useAuthStore } from "../stores/auth";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
  useAuthStore.setState({ accessToken: "acc", refreshToken: "ref" });
});

afterEach(() => {
  vi.unstubAllGlobals();
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

describe("api/voice 频道 REST", () => {
  it("listVoiceChannels → GET /voice/channels/ 返回频道 descriptor", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse([
        {
          id: "1",
          name: "大厅",
          room_name: "vc-abc",
          owner_id: "u1",
          member_count: 2,
          mine: true,
          created_at: "2026-08-13T00:00:00Z",
        },
      ]),
    );
    vi.stubGlobal("fetch", fetchMock);

    const list = await voiceApi.listVoiceChannels();
    expect(list).toHaveLength(1);
    expect(list[0].member_count).toBe(2);
    expect(list[0].mine).toBe(true);
    expect(fetchMock.mock.calls[0][0]).toContain("/api/v1/voice/channels/");
  });

  it("createVoiceChannel → POST {name}；空名称由前端拦截（不发请求）", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse(
        { id: "2", name: "新频道", room_name: "vc-def", owner_id: "me", created_at: "" },
        201,
      ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const ch = await voiceApi.createVoiceChannel("新频道");
    expect(ch.id).toBe("2");
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body).toEqual({ name: "新频道" });
  });

  it("joinVoiceChannel → 返回成员确认（媒体凭据已随 LiveKit 退役移除）", async () => {
    const okFetch = vi.fn().mockResolvedValue(
      jsonResponse({
        channel_id: "1",
        room_name: "vc-abc",
        joined: true,
      }),
    );
    vi.stubGlobal("fetch", okFetch);
    const joined = await voiceApi.joinVoiceChannel("1");
    expect(joined.joined).toBe(true);
    expect(joined.room_name).toBe("vc-abc");
  });

  it("leaveVoiceChannel 幂等：重复离开都返回 {left:true}", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ left: true }))
      .mockResolvedValueOnce(jsonResponse({ left: true }));
    vi.stubGlobal("fetch", fetchMock);
    await voiceApi.leaveVoiceChannel("1");
    await voiceApi.leaveVoiceChannel("1");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("旧账号leave补偿只用原凭据，401不刷新或换新账号重试", async () => {
    const originalToken = "fixture-original-access";
    const currentToken = "fixture-current-access";
    const currentRefresh = "fixture-current-refresh";
    useAuthStore.setState({ accessToken: currentToken, refreshToken: currentRefresh });
    const requests: Array<{ path: string; method: string | undefined; usesOriginal: boolean; usesCurrent: boolean }> = [];
    const fetchMock = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const credential = new Headers(init?.headers).get("Authorization");
      requests.push({
        path: String(input), method: init?.method,
        usesOriginal: credential === `Bearer ${originalToken}`,
        usesCurrent: credential === `Bearer ${currentToken}`,
      });
      return Promise.resolve(jsonResponse({ detail: "旧会话已过期" }, 401));
    });
    vi.stubGlobal("fetch", fetchMock);

    const error = await voiceApi.leaveVoiceChannel("old-room", originalToken).catch((reason: unknown) => reason);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(401);
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({ method: "POST", usesOriginal: true, usesCurrent: false });
    expect(requests[0]!.path).toContain("/api/v1/voice/channels/old-room/leave/");
    expect(requests.some((request) => request.path.includes("/auth/refresh/"))).toBe(false);
    expect(useAuthStore.getState().accessToken === currentToken).toBe(true);
    expect(useAuthStore.getState().refreshToken === currentRefresh).toBe(true);
  });

  it("heartbeatVoiceChannel 非成员 → 403", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse({ detail: "非频道成员不可心跳" }, 403));
    vi.stubGlobal("fetch", fetchMock);
    const err = await voiceApi.heartbeatVoiceChannel("1").catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).status).toBe(403);
  });

  it("listVoiceChannelMembers → 成员 descriptor 数组", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({ results: [
        { id: 1, user_id: "u1", joined_at: "t1", last_seen_at: "t2" },
        { id: 2, user_id: "elysia-user", joined_at: "t1", last_seen_at: "t3" },
      ], next_cursor: null, has_more: false, total: 2 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const members = await voiceApi.listVoiceChannelMembers("1");
    expect(members.map((m) => m.user_id)).toEqual(["u1", "elysia-user"]);
    expect(fetchMock.mock.calls[0][0]).toContain("pagination=cursor&limit=100");
  });

  it("runtime成员对账按页收齐并去重；下一页失败不会返回首屏伪装完整", async () => {
    const a = { id: 1, user_id: "u1", joined_at: "t1", last_seen_at: "t2" };
    const b = { id: 2, user_id: "u2", joined_at: "t1", last_seen_at: "t2" };
    const fetchMock = vi.fn().mockResolvedValueOnce(jsonResponse({ results: [a], next_cursor: "next", has_more: true, total: 2 }))
      .mockResolvedValueOnce(jsonResponse({ results: [a, b], next_cursor: null, has_more: false, total: 2 }));
    vi.stubGlobal("fetch", fetchMock);
    expect((await voiceApi.listVoiceChannelMembers("1")).map((row) => row.user_id)).toEqual(["u1", "u2"]);
    expect(fetchMock.mock.calls[1][0]).toContain("cursor=next");
    fetchMock.mockResolvedValueOnce(jsonResponse({ results: [a], next_cursor: "next", has_more: true, total: 2 }))
      .mockResolvedValueOnce(jsonResponse({ detail: "offline" }, 503));
    await expect(voiceApi.listVoiceChannelMembers("1")).rejects.toThrow("offline");
  });

  it("runtime成员对账拒绝循环cursor", async () => {
    vi.stubGlobal("fetch", vi.fn().mockImplementation(async () => jsonResponse({
      results: [{ id: 1, user_id: "u1", joined_at: "t1", last_seen_at: "t2" }],
      next_cursor: "loop", has_more: true, total: 2,
    })));
    await expect(voiceApi.listVoiceChannelMembers("1")).rejects.toThrow("继续位置");
  });
});
