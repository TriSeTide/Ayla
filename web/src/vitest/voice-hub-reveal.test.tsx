/**
 * VoiceHubPage 列表浮入测试（A2 扩展至群外语音）：
 * 异步频道列表就绪后，页面把 !channelsLoading 传给 VoiceChannelList，
 * 卡片外层用统一 .reveal-item + 40ms stagger 进入。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import * as voiceApi from "../api/voice";
import type { VoiceChannelDescriptor } from "../api/types";
import { VoiceHubPage } from "../pages/VoiceHubPage";
import { useShellStore } from "../stores/shell";
import { useVoiceStore } from "../stores/voice";

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));
vi.mock("../api/voice", () => ({
  listVoiceChannels: vi.fn(),
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
  useVoiceStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
  vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([channel("1"), channel("2"), channel("3")]);
});

afterEach(() => {
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
});

describe("VoiceHubPage 列表逐条浮入", () => {
  it("异步加载完成后为群外语音卡片应用 40ms stagger", async () => {
    const { container } = render(
      <MemoryRouter>
        <VoiceHubPage />
      </MemoryRouter>,
    );
    await screen.findByText("群外语音1");
    await waitFor(() => expect(container.querySelectorAll(".voice-channel-card-wrap")).toHaveLength(3));

    const cards = container.querySelectorAll(".voice-channel-card-wrap");
    expect(cards[0]).toHaveClass("reveal-item");
    expect(cards[0]).toHaveStyle({ "--reveal-delay": "0ms" });
    expect(cards[1]).toHaveStyle({ "--reveal-delay": "40ms" });
    expect(cards[2]).toHaveStyle({ "--reveal-delay": "80ms" });
  });
});
