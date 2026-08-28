/**
 * GroupVoice 测试（F5 R-G8）：群内语音房范围 = 仅该群（filter group === groupId）。
 * mock voiceApi.listVoiceChannels + VoiceChannelPanel/useVoiceChannel 的媒体链不触发
 * （列表态 currentChannelId=null，join 才触发）。
 * 房内态：mock VoiceRoomBody 为 onLeave 桩，聚焦 GroupVoice 的 handleLeave
 * （房主离开被拦截 / 非房主正常离开）。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, Route, Routes, useParams } from "react-router-dom";
import * as voiceApi from "../api/voice";
import type { UserPublic, VoiceChannelDescriptor } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { GroupVoice } from "../pages/group/GroupVoice";

vi.mock("../api/voice", () => ({
  listVoiceChannels: vi.fn(),
  listVoiceChannelMembers: vi.fn(),
  joinVoiceChannel: vi.fn(),
  leaveVoiceChannel: vi.fn(),
  heartbeatVoiceChannel: vi.fn(),
  createVoiceChannel: vi.fn(),
  listVoiceChatMessages: vi.fn().mockResolvedValue([]),
  sendVoiceChatMessage: vi.fn(),
}));

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));

vi.mock("../components/voice/VoiceRoomBody", () => ({
  VoiceRoomBody: (props: { channelName: string; onLeave: () => void }) => (
    <div>
      <span>{props.channelName}</span>
      <button type="button" onClick={props.onLeave}>
        离开频道
      </button>
    </div>
  ),
}));

const SELF: UserPublic = {
  id: "o1",
  username: "me",
  nickname: "我",
  avatar: "",
  signature: "",
  status: "online",
  online: true,
  date_joined: "2026-01-01T00:00:00Z",
};

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
  useAuthStore.setState({ currentUser: null });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
  useAuthStore.setState({ currentUser: null });
});

describe("GroupVoice 范围（仅该群）", () => {
  it("混合列表中只显示本群语音房", async () => {
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([
      ch("v1", "g1", "本群语音"),
      ch("v2", "g1", "本群语音2"),
      ch("v3", null, "公开语音"),
      ch("v4", "g9", "其它群"),
    ]);
    render(<MemoryRouter><GroupVoice groupId="g1" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "群内语音房" })).toBeInTheDocument();
    expect(document.querySelector(".group-scene-head")).not.toBeNull();
    expect(screen.getByText("本群语音2")).toBeInTheDocument();
    // A2 扩展：内容就绪后由 VoiceChannelList 为群内语音卡片挂 40ms stagger。
    const cards = document.querySelectorAll(".voice-channel-card-wrap");
    expect(cards).toHaveLength(2);
    expect(cards[0]).toHaveClass("reveal-item");
    expect(cards[0]).toHaveStyle({ "--reveal-delay": "0ms" });
    expect(cards[1]).toHaveStyle({ "--reveal-delay": "40ms" });
    expect(screen.queryByText("公开语音")).not.toBeInTheDocument();
    expect(screen.queryByText("其它群")).not.toBeInTheDocument();
  });

  it("多群白名单语音房（group=null + 白名单 13/14/15）出现在每个被选群的群内页", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([multi]);
    for (const gid of ["13", "14", "15"]) {
      const { unmount } = render(
        <MemoryRouter><GroupVoice groupId={gid} onExit={vi.fn()} /></MemoryRouter>,
      );
      await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
      unmount();
    }
  });

  it("多群白名单语音房不进其它群/公开房混入本群列表", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([
      multi,
      ch("vx", "9", "其它群语音"),
      ch("vpub", null, "公开语音"),
    ]);
    render(<MemoryRouter><GroupVoice groupId="13" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
    expect(screen.queryByText("其它群语音")).not.toBeInTheDocument();
    expect(screen.queryByText("公开语音")).not.toBeInTheDocument();
  });

  it("多群白名单语音房在群内 URL 下可进入房内视图", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([multi]);
    useVoiceStore.setState({ currentChannelId: "mv1" });
    render(
      <MemoryRouter>
        <GroupVoice groupId="13" routeChannelId="mv1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    // VoiceRoomBody mock 渲染 channelName + 离开频道按钮 → 房内视图
    await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "离开频道" })).toBeInTheDocument();
  });

  it("本群无语音房 → 空态引导", async () => {
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([ch("v3", null, "公开语音")]);
    render(<MemoryRouter><GroupVoice groupId="g1" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("群内还没有语音房")).toBeInTheDocument());
    // 群内建语音房入口在壳层 CreateFAB（shellConfig group-voice handler），空态仅提供返回聊天
    expect(screen.getByRole("button", { name: "返回聊天" })).toBeInTheDocument();
  });

  it("房主点离开频道 → 提示先转让房主，不调 leave/、不跳转", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([ch("v1", "g1", "本群语音")]);
    useVoiceStore.setState({ currentChannelId: "v1" });
    useAuthStore.setState({ currentUser: SELF });
    render(
      <MemoryRouter>
        <GroupVoice groupId="g1" routeChannelId="v1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());

    fireEvent.click(screen.getByRole("button", { name: "离开频道" }));

    expect(confirmSpy).toHaveBeenCalledWith("你是房主，退出前应先转让房主");
    expect(voiceApi.leaveVoiceChannel).not.toHaveBeenCalled();
    // 仍在房内视图（未被导航走，离开按钮还在）
    expect(screen.getByRole("button", { name: "离开频道" })).toBeInTheDocument();
    confirmSpy.mockRestore();
  });

  it("非房主点离开频道 → 正常调 leave/ 并离开", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue([ch("v1", "g1", "本群语音")]);
    vi.mocked(voiceApi.leaveVoiceChannel).mockResolvedValue({ left: true });
    useVoiceStore.setState({ currentChannelId: "v1" });
    useAuthStore.setState({ currentUser: { ...SELF, id: "other" } });
    // 用真实路由渲染：navigate 回列表（无 :voiceChannelId 段）后房内态消失
    function RouteGroupVoice() {
      const { id, voiceChannelId } = useParams<{ id: string; voiceChannelId?: string }>();
      return <GroupVoice groupId={id ?? ""} routeChannelId={voiceChannelId} onExit={vi.fn()} />;
    }
    render(
      <MemoryRouter initialEntries={["/group/g1/voice/v1"]}>
        <Routes>
          <Route path="/group/:id/voice/:voiceChannelId" element={<RouteGroupVoice />} />
        </Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());

    fireEvent.click(screen.getByRole("button", { name: "离开频道" }));

    expect(confirmSpy).not.toHaveBeenCalled();
    expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("v1");
    // 已导航回群内语音列表（房内视图消失，离开按钮不再存在）
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "离开频道" })).not.toBeInTheDocument(),
    );
    confirmSpy.mockRestore();
  });
});
