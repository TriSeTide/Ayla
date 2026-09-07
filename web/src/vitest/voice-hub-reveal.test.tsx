/**
 * VoiceHubPage 列表浮入测试（A2 扩展至群外语音）：
 * 异步首批频道就绪后，只为新增卡片播放 50ms stagger。
 */
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import * as voiceApi from "../api/voice";
import type { VoiceChannelDescriptor } from "../api/types";
import { VoiceHubPage } from "../pages/VoiceHubPage";
import { useShellStore } from "../stores/shell";
import { useVoiceStore } from "../stores/voice";
import { disposeDirectoryTracking } from "../stores/directory";

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));
vi.mock("../api/voice", () => ({
  listVoiceChannels: vi.fn(),
  listVoiceChannelsPage: vi.fn(),
  getVoiceChannel: vi.fn(),
}));
vi.mock("../ws/voice", () => ({ voiceWS: { connect: vi.fn() } }));
vi.mock("../hooks/useVoiceChannel", () => ({
  useVoiceChannel: () => ({
    currentChannelId: null,
    livekit: "idle",
    joining: false,
    error: null,
    clearError: vi.fn(),
    join: vi.fn(),
    leave: vi.fn(),
    toggleMic: vi.fn(),
    setMemberVolume: vi.fn(),
    setMemberLocallyMuted: vi.fn(),
    setLocalVolume: vi.fn(),
    rejoin: vi.fn(),
  }),
}));
vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
let animatedCards: Array<{ node: HTMLElement; delay: number | undefined }>;

function channel(id: string): VoiceChannelDescriptor {
  return {
    id,
    name: `群外语音${id}`,
    room_name: `room_${id}`,
    owner_id: "owner",
    member_count: 2,
    visibility: "public",
    group: null,
    group_name: null,
    mine: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

beforeEach(() => {
  disposeDirectoryTracking();
  useVoiceStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
  vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValue({ results: [channel("1"), channel("2"), channel("3")], next_cursor: null, has_more: false, total: 3, total_member_count: 6 });
  vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
  animatedCards = [];
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement, _frames: Keyframe[], options: KeyframeAnimationOptions) {
    if (this.matches(".voice-channel-card-wrap")) animatedCards.push({ node: this, delay: options.delay });
    return { cancel: vi.fn(), onfinish: null };
  } });
});

afterEach(() => {
  cleanup();
  disposeDirectoryTracking();
  vi.clearAllMocks();
  vi.unstubAllGlobals();
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
  useVoiceStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
});

describe("VoiceHubPage 列表逐条浮入", () => {
  it("异步加载完成后为群外语音卡片应用 50ms stagger", async () => {
    const { container } = render(
      <MemoryRouter>
        <VoiceHubPage />
      </MemoryRouter>,
    );
    await screen.findByText("群外语音1");
    await waitFor(() => expect(container.querySelectorAll(".voice-channel-card-wrap")).toHaveLength(3));

    const cards = container.querySelectorAll(".voice-channel-card-wrap");
    expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledWith({ groupId: undefined, onlyLive: undefined, limit: 20, cursor: null });
    expect(animatedCards.map((item) => item.node)).toEqual(Array.from(cards));
    expect(animatedCards.map((item) => item.delay)).toEqual([0, 50, 100]);
  });
});
