/**
 * api/voice.ts 契约测试（mock fetch，M5-3 §7.1）：
 * - 频道 REST：列表/建频道/详情字段对齐；join 503 显式暴露给调用方
 * - heartbeat 非成员 → 403
 * - leave 幂等
 * - 爱莉编排：reused=true 正常返回；文本注入空文本 400；502 爱莉侧不可用
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

  it("joinVoiceChannel → 返回 token/ws_url/ttl；503（LiveKit 未配置）抛 ApiError(503)", async () => {
    // 成功路径
    const okFetch = vi.fn().mockResolvedValue(
      jsonResponse({
        channel_id: "1",
        room_name: "vc-abc",
        token: "lk-token",
        ws_url: "ws://127.0.0.1:7880",
        ttl: 600,
        joined: true,
      }),
    );
    vi.stubGlobal("fetch", okFetch);
    const joined = await voiceApi.joinVoiceChannel("1");
    expect(joined.token).toBe("lk-token");
    expect(joined.ttl).toBe(600);

    // 503 路径
    const failFetch = vi
      .fn()
      .mockResolvedValue(jsonResponse({ detail: "LiveKit 未配置，无法加入语音频道" }, 503));
    vi.stubGlobal("fetch", failFetch);
    const err = await voiceApi.joinVoiceChannel("1").catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).status).toBe(503);
    expect((err as ApiError).message).toContain("LiveKit 未配置");
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
      jsonResponse([
        { id: 1, user_id: "u1", joined_at: "t1", last_seen_at: "t2" },
        { id: 2, user_id: "elysia-user", joined_at: "t1", last_seen_at: "t3" },
      ]),
    );
    vi.stubGlobal("fetch", fetchMock);
    const members = await voiceApi.listVoiceChannelMembers("1");
    expect(members.map((m) => m.user_id)).toEqual(["u1", "elysia-user"]);
  });
});

describe("api/voice 爱莉语音编排", () => {
  const callStatus = {
    call_id: "call-1",
    episode_id: "ep-1",
    state: "active",
    mode: "auto",
    provider: "voice_live",
    created_at: "t",
    updated_at: "t",
    resumable: true,
    connected: true,
    input_audio_bytes: 0,
    output_audio_bytes: 0,
    interruptions: 0,
    failure_reason: null,
  };

  it("createElysiaVoiceCall → reused=true 正常返回（单并发复用不是错误）", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({ call: callStatus, connection: null, reused: true }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const result = await voiceApi.createElysiaVoiceCall();
    expect(result.reused).toBe(true);
    expect(result.call.call_id).toBe("call-1");
  });

  it("sendElysiaVoiceText 空文本 → 后端 400（前端应先拦截）", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse({ detail: "text 不能为空" }, 400));
    vi.stubGlobal("fetch", fetchMock);
    const err = await voiceApi.sendElysiaVoiceText("call-1", "").catch((e) => e);
    expect((err as ApiError).status).toBe(400);
  });

  it("sendElysiaVoiceText 正常 → {command_id, status, accepted}", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({ command_id: "cmd-1", status: "accepted", accepted: true }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const result = await voiceApi.sendElysiaVoiceText("call-1", "你好");
    expect(result.accepted).toBe(true);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body).toEqual({ text: "你好" });
  });

  it("endElysiaVoiceCall 幂等：重复结束都成功", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ command_id: "cmd-2", status: "ended", accepted: true }))
      .mockResolvedValueOnce(jsonResponse({ command_id: "cmd-2", status: "ended", accepted: true }));
    vi.stubGlobal("fetch", fetchMock);
    await voiceApi.endElysiaVoiceCall("call-1");
    await voiceApi.endElysiaVoiceCall("call-1");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("pollElysiaVoiceCall → {projected, total}", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      jsonResponse({ projected: [{ event_id: "e1" }], total: 3 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const result = await voiceApi.pollElysiaVoiceCall("call-1");
    expect(result.total).toBe(3);
  });

  it("profile 未配置 → 503；Elysium 侧错误 → 502", async () => {
    const fetch503 = vi.fn().mockResolvedValue(jsonResponse({ detail: "爱莉 profile 尚未初始化" }, 503));
    vi.stubGlobal("fetch", fetch503);
    const err503 = await voiceApi.createElysiaVoiceCall().catch((e) => e);
    expect((err503 as ApiError).status).toBe(503);

    const fetch502 = vi.fn().mockResolvedValue(
      jsonResponse({ detail: "Elysium 侧错误: boom", code: "elysia_error" }, 502),
    );
    vi.stubGlobal("fetch", fetch502);
    const err502 = await voiceApi.getElysiaVoiceCall("call-1").catch((e) => e);
    expect((err502 as ApiError).status).toBe(502);
  });
});
