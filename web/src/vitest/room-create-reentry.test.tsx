import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import * as voiceApi from "../api/voice";
import * as gameApi from "../api/boardgame";
import { VoiceChannelCreate } from "../components/voice/VoiceChannelCreate";
import { GameRoomCreate } from "../components/boardgame/GameRoomCreate";
import { useVoiceStore } from "../stores/voice";

vi.mock("../api/voice", () => ({ createVoiceChannel: vi.fn() }));
vi.mock("../api/boardgame", () => ({ createGameRoom: vi.fn() }));
vi.mock("../components/VisibilitySelector", () => ({ VisibilitySelector: () => null }));

beforeEach(() => { vi.clearAllMocks(); useVoiceStore.getState().reset(); });

describe("room create request ownership", () => {
  it.each(["voice", "game"] as const)("%s holds a synchronous submit lock through failure and allows one retry", async (kind) => {
    let rejectFirst!: (error: Error) => void;
    const api = kind === "voice" ? vi.mocked(voiceApi.createVoiceChannel) : vi.mocked(gameApi.createGameRoom);
    api.mockImplementationOnce(() => new Promise<never>((_, reject) => { rejectFirst = reject; }));
    api.mockResolvedValueOnce({ id: kind === "voice" ? "v1" : 1, name: "保留草稿" } as never);
    const onCreated = vi.fn();
    render(kind === "voice" ? <VoiceChannelCreate onCreated={onCreated} /> : <GameRoomCreate onCreated={onCreated} />);
    const input = screen.getByPlaceholderText(kind === "voice" ? "新语音频道名称" : "桌游室名称");
    fireEvent.change(input, { target: { value: "保留草稿" } });
    act(() => {
      // React batches these native events in one act: state alone cannot guard both.
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(api).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button")).toBeDisabled();
    await act(async () => rejectFirst(new Error("合成创建失败")));
    await waitFor(() => expect(screen.getByText("合成创建失败")).toBeInTheDocument());
    expect(input).toHaveValue("保留草稿");
    expect(onCreated).not.toHaveBeenCalled();
    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(onCreated).toHaveBeenCalledTimes(1));
    expect(api).toHaveBeenCalledTimes(2);
  });
});
