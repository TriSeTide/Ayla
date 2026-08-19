/**
 * boardgame API 契约测试（F7）：列表 ?mine=1、创建 body、join/leave URL。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as boardgameApi from "../api/boardgame";
import { useAuthStore } from "../stores/auth";

const fetchMock = vi.fn();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockResolvedValue(
    new Response(JSON.stringify([]), { status: 200, headers: { "Content-Type": "application/json" } }),
  );
  useAuthStore.setState({ accessToken: null, refreshToken: null });
});

afterEach(() => {
  vi.unstubAllGlobals();
  fetchMock.mockReset();
});

function calledUrl(call = 0): string {
  return fetchMock.mock.calls[call][0] as string;
}

describe("boardgame API", () => {
  it("listGameRooms mine → ?mine=1", async () => {
    await boardgameApi.listGameRooms({ mine: true });
    expect(calledUrl()).toContain("/boardgame/rooms/?mine=1");
  });

  it("listGameRooms 默认无 query", async () => {
    await boardgameApi.listGameRooms();
    expect(calledUrl()).toContain("/boardgame/rooms/");
    expect(calledUrl()).not.toContain("mine");
  });

  it("createGameRoom 带 name + group", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ id: 1 }), { status: 201, headers: { "Content-Type": "application/json" } }),
    );
    await boardgameApi.createGameRoom({ name: "狼人杀", group: "5" });
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body).toMatchObject({ name: "狼人杀", group: "5" });
  });

  it("joinGameRoom 走 :join 路径", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ id: 1 }), { status: 201, headers: { "Content-Type": "application/json" } }),
    );
    await boardgameApi.joinGameRoom(7);
    expect(calledUrl()).toContain("/boardgame/rooms/7:join/");
  });

  it("leaveGameRoom 走 :leave 路径", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ left: true }), { status: 200, headers: { "Content-Type": "application/json" } }),
    );
    await boardgameApi.leaveGameRoom(7);
    expect(calledUrl()).toContain("/boardgame/rooms/7:leave/");
  });
});
