/**
 * GroupVoice 测试（F5 R-G8）：群内语音房范围 = 仅该群（filter group === groupId）。
 * mock voiceApi.listVoiceChannels + VoiceChannelPanel/useVoiceChannel 的媒体链不触发
 * （列表态 currentChannelId=null，join 才触发）。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import type { VoiceChannelDescriptor } from "../api/types";
import { useVoiceStore } from "../stores/voice";
import { GroupVoice } from "../pages/group/GroupVoice";

vi.mock("../api/voice", () => ({
  listVoiceChannels: vi.fn(),
  listVoiceChannelMembers: vi.fn(),
  joinVoiceChannel: vi.fn(),
  leaveVoiceChannel: vi.fn(),
  heartbeatVoiceChannel: vi.fn(),
  createVoiceChannel: vi.fn(),
}));

function ch(id: string, group: string | null, name = id): VoiceChannelDescriptor {
  return {
    id,
    name,
    room_name: `room_${id}`,
    owner_id: "o1",
    member_count: 1,
    visibility: group ? "group" : "public",
    group,
    group_name: group ? "目标群" : null,
    mine: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

beforeEach(() => {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() })),
  );
  useVoiceStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
});

describe("GroupVoice 范围（仅该群）", () => {
  it("混合列表中只显示本群语音房", async () => {
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([
      ch("v1", "g1", "本群语音"),
      ch("v2", "g1", "本群语音2"),
      ch("v3", null, "公开语音"),
      ch("v4", "g9", "其它群"),
    ]);
    render(<GroupVoice groupId="g1" onExit={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());
    expect(screen.getByText("本群语音2")).toBeInTheDocument();
    expect(screen.queryByText("公开语音")).not.toBeInTheDocument();
    expect(screen.queryByText("其它群")).not.toBeInTheDocument();
  });

  it("本群无语音房 → 空态引导", async () => {
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([ch("v3", null, "公开语音")]);
    render(<GroupVoice groupId="g1" onExit={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("群内还没有语音房")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "创建群内语音房" }));
    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: "创建群内语音房" })).toBeInTheDocument(),
    );
    expect(screen.getByPlaceholderText("新语音频道名称")).toBeInTheDocument();
  });
});
