import { beforeEach, describe, expect, it, vi } from "vitest";
import { apiRequest } from "../api/client";
import { listLiveChannels, listLiveChannelsPage } from "../api/live";
import { listVoiceChannels, listVoiceChannelsPage } from "../api/voice";
import { listGameRooms, listGameRoomsPage } from "../api/boardgame";

vi.mock("../api/client", () => ({ apiRequest: vi.fn() }));

beforeEach(() => vi.mocked(apiRequest).mockReset().mockResolvedValue({ results: [], next_cursor: null, has_more: false, total: 0 }));

describe("bounded directory API contracts", () => {
  it.each([
    [listLiveChannelsPage, "/live/channels/"],
    [listVoiceChannelsPage, "/voice/channels/"],
    [listGameRoomsPage, "/boardgame/rooms/"],
  ] as const)("requests a real server page, preserves cursor bytes and filters before paging", async (list, path) => {
    await list({ groupId: "42", cursor: "next/+== &汉", limit: 20 });
    const url = new URL(vi.mocked(apiRequest).mock.calls[0][0], "https://ayla.test");
    expect(url.pathname).toBe(path);
    expect(Object.fromEntries(url.searchParams)).toEqual({ limit: "20", cursor: "next/+== &汉", group_id: "42" });
  });

  it("live only-live is part of the server query, including the first page", async () => {
    await listLiveChannelsPage({ onlyLive: true });
    const query = new URL(vi.mocked(apiRequest).mock.calls[0][0], "https://ayla.test").searchParams;
    expect(query.get("limit")).toBe("20");
    expect(query.get("only_live")).toBe("1");
    expect(query.has("cursor")).toBe(false);
  });

  it("legacy array consumers retain their explicit old API contract", async () => {
    await listLiveChannels();
    await listVoiceChannels();
    await listGameRooms();
    expect(vi.mocked(apiRequest).mock.calls.map(([path]) => path)).toEqual([
      "/live/channels/", "/voice/channels/", "/boardgame/rooms/",
    ]);
  });
});
