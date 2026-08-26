/**
 * VoiceHubPage 底栏下滑走回归测试（R-V2）。
 *
 * 回归背景：/voice 与 /voice/:id 共用 VoiceHubPage，全局页面转场
 * （AppShell AnimatePresence + resolvePageKey 用原始 pathname 作 key）会让
 * 旧大厅实例与新房间实例并存约 150ms。若大厅实例也注册 bottomTabsLeaving
 * cleanup（无条件置 false），会在新房间实例置 true 之后被其卸载 cleanup 覆盖，
 * 底栏滑出一半又被拉回（用户实测：进语音房底栏不下滑）。修复 = 仅房内注册 effect。
 *
 * 本测试真实渲染 AppShell 转场链路，断言转场完成（旧实例已卸载）后状态保持。
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useNavigate } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { VoiceChannelDescriptor } from "../api/types";
import { AppShell } from "../layout/AppShell";
import { VoiceHubPage } from "../pages/VoiceHubPage";
import { useAuthStore } from "../stores/auth";
import { useBadgesStore } from "../stores/badges";
import { useShellStore } from "../stores/shell";
import { useVoiceStore } from "../stores/voice";

// mock 一律用纯 async 实现（不用 mockResolvedValue）：不受 restoreAllMocks/clearAllMocks 影响
vi.mock("../api/elysia", () => ({
  getElysiaProfile: async () => ({ enabled: false }),
}));

vi.mock("../api/voice", async () => {
  const actual = await vi.importActual<typeof import("../api/voice")>("../api/voice");
  const channel = {
    id: "v1",
    name: "语音房一",
    room_name: "room-v1",
    owner_id: "u2",
    member_count: 1,
    visibility: "public" as const,
    group: null,
    group_name: null,
    mine: true,
    created_at: new Date().toISOString(),
  };
  return {
    ...actual,
    listVoiceChannels: async () => [channel],
    getVoiceChannel: async () => channel,
  };
});

vi.mock("../ws/voice", () => ({
  voiceWS: { connect: vi.fn(), disconnect: vi.fn() },
}));

// 只编排 join/leave 的 hook 在此不参与断言，替身隔离 LiveKit/心跳等重依赖
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

// 大厅/房间本体替换为可定位替身；被测对象是 shell store 状态时序，不是其内部 UI
vi.mock("../components/voice/VoiceRoomBody", () => ({
  VoiceRoomBody: () => <div data-testid="voice-room-body" />,
}));
vi.mock("../components/voice/VoiceChannelList", () => ({
  VoiceChannelList: () => <div data-testid="voice-hub-list" />,
}));

const NARROW = "(max-width: 768px)";

function mockMatchMedia(narrow: boolean) {
  let matches = narrow;
  const listeners = new Set<(e: { matches: boolean }) => void>();
  const mql = {
    get matches() {
      return matches;
    },
    media: NARROW,
    onchange: null,
    addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) =>
      listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

let navigateRef: (to: string) => void = () => {};
function NavProbe() {
  navigateRef = useNavigate();
  return null;
}

function renderHub(initialPath: string) {
  mockMatchMedia(true);
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <NavProbe />
      <Routes>
        <Route element={<AppShell />}>
          <Route path="/voice" element={<VoiceHubPage />} />
          <Route path="/voice/:channelId" element={<VoiceHubPage />} />
        </Route>
      </Routes>
    </MemoryRouter>,
  );
}

function stubChannel(): VoiceChannelDescriptor {
  return {
    id: "v1",
    name: "语音房一",
    room_name: "room-v1",
    owner_id: "u2",
    member_count: 1,
    visibility: "public",
    group: null,
    group_name: null,
    mine: true,
    created_at: new Date().toISOString(),
  };
}

beforeEach(() => {
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: {
      id: "u1",
      username: "alice",
      nickname: "爱丽丝",
      avatar: "",
      signature: "",
      status: "online",
      online: true,
      date_joined: new Date().toISOString(),
    },
  });
  useBadgesStore.setState({ badges: null });
  useShellStore.setState({ bottomTabsLeaving: false });
  // 预置频道列表（含 lastFetched 避免 isVoiceStale 判过期触发重拉）：大厅直接出列表、
  // 房内直接出面板，不依赖网络返回时序
  useVoiceStore.setState({
    channels: [stubChannel()],
    channelsLoading: false,
    lastFetched: Date.now(),
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useVoiceStore.setState({ channels: [], channelsLoading: false, lastFetched: null });
});

describe("VoiceHubPage 进语音房底栏下滑走（R-V2 回归）", () => {
  it("/voice → /voice/:id 转场完成后底栏保持让位（旧大厅实例 cleanup 不覆盖）", async () => {
    renderHub("/voice");
    await screen.findByTestId("voice-hub-list");
    expect(useShellStore.getState().bottomTabsLeaving).toBe(false);

    act(() => navigateRef("/voice/v1"));
    await screen.findByTestId("voice-room-body");
    expect(useShellStore.getState().bottomTabsLeaving).toBe(true);

    // 等页面转场结束（AnimatePresence 移除旧大厅实例）；修复前此刻 cleanup 会复位成 false
    await waitFor(() =>
      expect(screen.queryByTestId("voice-hub-list")).not.toBeInTheDocument(),
    );
    expect(useShellStore.getState().bottomTabsLeaving).toBe(true);
  });

  it("/voice/:id → /voice 返回后底栏复位", async () => {
    renderHub("/voice/v1");
    await screen.findByTestId("voice-room-body");
    expect(useShellStore.getState().bottomTabsLeaving).toBe(true);

    act(() => navigateRef("/voice"));
    await screen.findByTestId("voice-hub-list");
    await waitFor(() =>
      expect(screen.queryByTestId("voice-room-body")).not.toBeInTheDocument(),
    );
    expect(useShellStore.getState().bottomTabsLeaving).toBe(false);
  });

  it("直接加载 /voice/:id（刷新场景）同样置位", async () => {
    renderHub("/voice/v1");
    await screen.findByTestId("voice-room-body");
    expect(useShellStore.getState().bottomTabsLeaving).toBe(true);
  });
});
