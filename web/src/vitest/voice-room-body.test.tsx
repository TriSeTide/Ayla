/** VoiceRoomBody 房内独立聊天测试：不再把消息发送到群聊。 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";

vi.mock("../components/voice/VoiceChannelPanel", () => ({
  VoiceChannelPanel: () => <div>语音面板</div>,
}));
vi.mock("../api/voice", async () => {
  const actual = await vi.importActual<typeof import("../api/voice")>("../api/voice");
  return {
    ...actual,
    listVoiceChatMessages: vi.fn().mockResolvedValue([]),
    sendVoiceChatMessage: vi.fn(),
  };
});

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

afterEach(() => {
  vi.clearAllMocks();
});

describe("VoiceRoomBody 房内独立聊天", () => {
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

  it("群外进入语音房时，输入框完整复用直播间的底部滑入动画", () => {
    const { container, rerender } = renderBody("v1", false);
    expect(container.querySelector(".voice-room-composer")).toHaveStyle({ transform: "translateY(100%)" });
    expect(container.querySelector(".voice-room-composer")).toHaveStyle({ transition: "transform 250ms var(--ease-out)" });

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
  });
});
