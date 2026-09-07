/** VoiceRoomBody 房内独立聊天测试：不再把消息发送到群聊。 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";
import { voiceWS } from "../ws/voice";

const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");

vi.mock("../components/voice/VoiceChannelPanel", () => ({
  VoiceChannelPanel: () => <div>语音面板</div>,
}));
vi.mock("../api/voice", async () => {
  const actual = await vi.importActual<typeof import("../api/voice")>("../api/voice");
  return {
    ...actual,
    listVoiceChatMessagesPage: vi.fn().mockResolvedValue({ results: [], next_cursor: null, has_more: false, total: 0 }),
    sendVoiceChatMessage: vi.fn(),
  };
});

// 捕获 voiceWS.onFrame 注册的 handler，以便在测试里模拟 WS 回播先于乐观 append 到达
const wsMock = vi.hoisted(() => {
  let handler: ((frame: unknown) => void) | null = null;
  return {
    setHandler(h: ((frame: unknown) => void) | null) {
      handler = h;
    },
    emit(frame: unknown) {
      handler?.(frame);
    },
  };
});
vi.mock("../ws/voice", () => ({
  voiceWS: {
    onFrame(h: (frame: unknown) => void) {
      wsMock.setHandler(h);
      return () => wsMock.setHandler(null);
    },
  },
}));

function renderBody(channelId?: string, inputEntered = true) {
  return render(
    <VoiceRoomBody
      channelId={channelId}
      channelName="语音房"
      livekit="connected"
      wsConnection="online"
      elysiaProfile={null}
      onToggleMic={vi.fn()}
      onLeave={vi.fn()}
      onRejoin={vi.fn()}
      onVolumeChange={vi.fn()}
      onLocalVolumeChange={vi.fn()}
      onToggleMemberMuted={vi.fn()}
      onBack={vi.fn()}
      inputEntered={inputEntered}
    />,
  );
}

beforeEach(() => {
  vi.mocked(voiceApi.listVoiceChatMessagesPage).mockResolvedValue({ results: [], next_cursor: null, has_more: false, total: 0 });
});

afterEach(() => {
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

describe("VoiceRoomBody 房内独立聊天", () => {
  it.each([false, true])("换房在原三块DOM重播、取消旧动画且不重复订阅（narrow=%s）", async (narrow) => {
    let reduced = false;
    const listeners = new Set<() => void>();
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
      get matches() { return query === "(max-width: 768px)" ? narrow : query.includes("prefers-reduced-motion") && reduced; },
      addEventListener: (_name: string, cb: () => void) => listeners.add(cb),
      removeEventListener: (_name: string, cb: () => void) => listeners.delete(cb),
    })));
    const played: Array<{ node: HTMLElement; frames: Keyframe[]; options: KeyframeAnimationOptions; cancel: ReturnType<typeof vi.fn> }> = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement, frames: Keyframe[], options: KeyframeAnimationOptions) {
      const record = { node: this, frames, options, cancel: vi.fn() };
      played.push(record);
      return { cancel: record.cancel };
    } });
    const onFrame = vi.spyOn(voiceWS, "onFrame");
    const props = { channelName: "语音房", livekit: "connected" as const, wsConnection: "online" as const, elysiaProfile: null, onToggleMic: vi.fn(), onLeave: vi.fn(), onRejoin: vi.fn(), onVolumeChange: vi.fn(), onLocalVolumeChange: vi.fn(), onToggleMemberMuted: vi.fn(), onBack: vi.fn(), inputEntered: true };
    const { container, rerender, unmount } = render(<VoiceRoomBody {...props} channelId="v1" />);
    await waitFor(() => expect(voiceApi.listVoiceChatMessagesPage).toHaveBeenCalledWith("v1", { cursor: null, beforeId: undefined }));
    expect(played).toHaveLength(3);
    expect(played.every(({ options }) => options.duration === 300 && options.easing === "cubic-bezier(0,0,0.58,1)")).toBe(true);
    expect(played.map(({ frames }) => frames[0].transform)).toEqual(["translate(0px, -20px)", narrow ? "translate(0px, 20px)" : "translate(20px, 0px)", "translate(0px, 20px)"]);
    const oldNodes = played.map(({ node }) => node);
    const input = container.querySelector("textarea");
    rerender(<VoiceRoomBody {...props} channelId="v2" />);
    await waitFor(() => expect(voiceApi.listVoiceChatMessagesPage).toHaveBeenCalledWith("v2", { cursor: null, beforeId: undefined }));
    expect(played).toHaveLength(6);
    expect(played.slice(3).map(({ node }) => node)).toEqual(oldNodes);
    expect(played.slice(0, 3).every(({ cancel }) => cancel.mock.calls.length === 1)).toBe(true);
    expect(container.querySelector("textarea")).toBe(input);
    expect(onFrame).toHaveBeenCalledTimes(2);
    act(() => { reduced = true; Array.from(listeners).forEach((listener) => listener()); });
    expect(played.slice(3).every(({ cancel }) => cancel.mock.calls.length === 1)).toBe(true);
    rerender(<VoiceRoomBody {...props} channelId="v3" />);
    await waitFor(() => expect(voiceApi.listVoiceChatMessagesPage).toHaveBeenCalledWith("v3", { cursor: null, beforeId: undefined }));
    expect(played).toHaveLength(6);
    expect(onFrame).toHaveBeenCalledTimes(3);
    unmount();
    expect(played.every(({ cancel }) => cancel.mock.calls.length === 1)).toBe(true);
  });
  it("语音房显示独立输入框并发送到 voice chat API", async () => {
    vi.mocked(voiceApi.sendVoiceChatMessage).mockResolvedValue({
      id: "m1",
      channel_id: "v1",
      sender: { user_id: "u1", nickname: "我", avatar: "" },
      content: "大家好",
      media_id: null,
      media: null,
      created_at: new Date().toISOString(),
    });
    renderBody("v1");
    const input = screen.getByPlaceholderText("在语音房内聊天");
    fireEvent.change(input, { target: { value: "大家好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送语音房消息" }));
    await waitFor(() =>
      expect(voiceApi.sendVoiceChatMessage).toHaveBeenCalledWith("v1", {
        content: "大家好",
        media_id: null,
      }),
    );
  });

  it("尚未进入语音房时不显示独立聊天输入框", () => {
    renderBody();
    expect(screen.queryByPlaceholderText("在语音房内聊天")).not.toBeInTheDocument();
  });

  it("输入区由聊天卡单独带入，不再叠加旧100%位移和延迟动画", () => {
    const { container, rerender } = renderBody("v1", false);
    const composer = container.querySelector(".voice-room-composer");
    expect(composer).toHaveStyle({ transform: "translateY(0)", transition: "none" });

    rerender(
      <VoiceRoomBody
        channelId="v1"
        channelName="语音房"
        livekit="connected"
        wsConnection="online"
        elysiaProfile={null}
        onToggleMic={vi.fn()}
        onLeave={vi.fn()}
        onRejoin={vi.fn()}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMemberMuted={vi.fn()}
        onBack={vi.fn()}
        inputEntered
      />,
    );
    expect(container.querySelector(".voice-room-composer")).toHaveStyle({ transform: "translateY(0)" });
    expect(container.querySelector(".voice-room-composer")).toBe(composer);
  });

  it("WS 回播先于乐观 append 到达时不渲染双气泡", async () => {
    const msg = {
      id: "m1",
      channel_id: "v1",
      sender: { user_id: "u1", nickname: "我", avatar: "" },
      content: "大家好",
      media_id: null,
      media: null,
      created_at: new Date().toISOString(),
    };
    vi.mocked(voiceApi.sendVoiceChatMessage).mockResolvedValue(msg);
    renderBody("v1");
    // 后端先 group_send 广播、后返回 POST 响应：WS 回播先于 sendMessage 的 await 完成到达
    act(() => {
      wsMock.emit({ type: "voice.chat.message", data: msg });
    });
    const input = screen.getByPlaceholderText("在语音房内聊天");
    fireEvent.change(input, { target: { value: "大家好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送语音房消息" }));
    await waitFor(() => expect(voiceApi.sendVoiceChatMessage).toHaveBeenCalled());
    // 双向按 id 去重：乐观 append 与 WS 回播谁先到，都只渲染一条
    await waitFor(() =>
      expect(document.querySelectorAll(".voice-room-chat-message")).toHaveLength(1),
    );
  });

  it("旧房发送迟到不清空新房草稿，同房发送期间继续编辑也保留新文字", async () => {
    let resolveSend!: (value: Awaited<ReturnType<typeof voiceApi.sendVoiceChatMessage>>) => void;
    vi.mocked(voiceApi.sendVoiceChatMessage).mockImplementationOnce(() => new Promise((resolve) => { resolveSend = resolve; }));
    const props = { channelName: "语音房", livekit: "connected" as const, wsConnection: "online" as const, elysiaProfile: null,
      onToggleMic: vi.fn(), onLeave: vi.fn(), onRejoin: vi.fn(), onVolumeChange: vi.fn(), onLocalVolumeChange: vi.fn(),
      onToggleMemberMuted: vi.fn(), onBack: vi.fn(), inputEntered: true };
    const { rerender } = render(<VoiceRoomBody {...props} channelId="old" />);
    fireEvent.change(screen.getByPlaceholderText("在语音房内聊天"), { target: { value: "旧房发送" } });
    fireEvent.click(screen.getByRole("button", { name: "发送语音房消息" }));
    rerender(<VoiceRoomBody {...props} channelId="new" />);
    fireEvent.change(screen.getByPlaceholderText("在语音房内聊天"), { target: { value: "新房草稿" } });
    const reply = { id: "77", channel_id: "old", sender: { user_id: "me", nickname: "me", avatar: "" }, content: "旧房发送", media_id: null, media: null, created_at: "2026-09-08T00:00:00Z" };
    await act(async () => resolveSend(reply));
    expect(screen.getByPlaceholderText("在语音房内聊天")).toHaveValue("新房草稿");
    expect(screen.queryByText("旧房发送")).not.toBeInTheDocument();
    vi.mocked(voiceApi.sendVoiceChatMessage).mockImplementationOnce(() => new Promise((resolve) => { resolveSend = resolve; }));
    fireEvent.click(screen.getByRole("button", { name: "发送语音房消息" }));
    fireEvent.change(screen.getByPlaceholderText("在语音房内聊天"), { target: { value: "继续编辑" } });
    await act(async () => resolveSend({ ...reply, id: "78", channel_id: "new", content: "新房草稿" }));
    expect(screen.getByPlaceholderText("在语音房内聊天")).toHaveValue("继续编辑");
  });
});
