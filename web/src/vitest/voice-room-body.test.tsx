/**
 * VoiceRoomBody 房内打字测试（F5，开发文档 §1.9 复用群会话）：
 * - 群语音房（groupId 非空）显示打字框，发送走 chatApi.sendMessage 到该群；
 * - 公开语音房（groupId=null）不显示打字框。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";

vi.mock("../components/voice/VoiceChannelPanel", () => ({
  VoiceChannelPanel: () => <div>语音面板</div>,
}));
vi.mock("../api/chat", () => ({
  sendMessage: vi.fn(),
}));

function renderBody(groupId: string | null) {
  return render(
    <VoiceRoomBody
      channelName="语音房"
      livekit="connected"
      wsConnection="online"
      elysiaProfile={null}
      groupId={groupId}
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
}

afterEach(() => {
  vi.clearAllMocks();
});

describe("VoiceRoomBody 房内打字", () => {
  it("群语音房显示打字框，发送走 chatApi.sendMessage 到该群", async () => {
    vi.mocked(chatApi.sendMessage).mockResolvedValue({} as never);
    renderBody("g1");
    const input = screen.getByPlaceholderText("在语音房内打字（发送到群消息）");
    fireEvent.change(input, { target: { value: "大家好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送语音房消息" }));
    await waitFor(() =>
      expect(chatApi.sendMessage).toHaveBeenCalledWith(
        "g1",
        expect.objectContaining({ type: "text", content: "大家好" }),
      ),
    );
  });

  it("公开语音房（groupId=null）不显示打字框", () => {
    renderBody(null);
    expect(screen.queryByPlaceholderText("在语音房内打字（发送到群消息）")).not.toBeInTheDocument();
  });
});
