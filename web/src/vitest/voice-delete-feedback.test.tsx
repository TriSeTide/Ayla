import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import * as voiceApi from "../api/voice";
import { VoiceHubPage } from "../pages/VoiceHubPage";
import { GroupVoice } from "../pages/group/GroupVoice";
import { useVoiceStore } from "../stores/voice";
import type { VoiceChannelDescriptor } from "../api/types";

const stubs = vi.hoisted(() => ({ join: vi.fn(), refresh: vi.fn(), resetLocal: vi.fn() }));
vi.mock("../api/voice", () => ({ deleteVoiceChannel: vi.fn(), getVoiceChannel: vi.fn() }));
vi.mock("../api/elysia", () => ({ getElysiaProfile: async () => ({ enabled: false }) }));
vi.mock("../ws/voice", () => ({ voiceWS: { connect: vi.fn() } }));
vi.mock("../hooks/useListEntryMotion", () => ({ useListEntryMotion: vi.fn() }));
vi.mock("../hooks/useDirectoryPage", () => ({ useDirectoryPage: () => ({ items: [], refresh: stubs.refresh, loading: false }) }));
vi.mock("../hooks/useVoiceChannel", () => ({ useVoiceChannel: () => ({ join: stubs.join, resetLocal: stubs.resetLocal,
  currentChannelId: "v1", livekit: "connected", joining: false, error: null }) }));
vi.mock("../components/voice/VoiceRoomBody", () => ({ VoiceRoomBody: ({ connectionError, onDeleteChannel }: { connectionError: string | null; onDeleteChannel: () => void }) =>
  <section data-testid="current-voice-room"><button onClick={onDeleteChannel}>删除房间</button>{connectionError && <p role="alert">{connectionError}</p>}</section> }));

beforeEach(() => {
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
  useVoiceStore.getState().setChannels([{ id: "v1", name: "当前语音房", allowed_group_ids: ["g1"] } as VoiceChannelDescriptor]);
});

describe("current voice room delete failure", () => {
  it.each([false, true])("keeps the room and silently drops the failed delete in the %s group variant", async (group) => {
    // bcb00dc 起删除失败静默：无错误提示；核心意图保留——房间保留、不重置本地媒体状态。
    vi.mocked(voiceApi.deleteVoiceChannel).mockRejectedValue(new Error("删除被拒绝"));
    render(<MemoryRouter initialEntries={["/voice/v1"]}><Routes><Route path="/voice/:channelId" element={group
      ? <GroupVoice groupId="g1" routeChannelId="v1" onExit={vi.fn()} /> : <VoiceHubPage />} /></Routes></MemoryRouter>);
    fireEvent.click(screen.getByRole("button", { name: "删除房间" }));
    fireEvent.click(screen.getByRole("button", { name: /^删除$/ }));
    await waitFor(() => expect(voiceApi.deleteVoiceChannel).toHaveBeenCalled());
    expect(screen.getByTestId("current-voice-room")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(stubs.resetLocal).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "删除房间" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "取消" }));
    expect(voiceApi.deleteVoiceChannel).toHaveBeenCalledTimes(1);
  });
});
