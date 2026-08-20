import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import * as voiceApi from "../api/voice";
import { CreateFab } from "../layout/CreateFab";
import type { FabAction } from "../layout/shellConfig";
import { useVoiceStore } from "../stores/voice";

vi.mock("../api/voice", () => ({
  createVoiceChannel: vi.fn(),
}));

vi.mock("../components/VisibilitySelector", () => ({
  VisibilitySelector: () => <div>可见范围</div>,
}));

const CHANNEL = {
  id: "voice-1",
  name: "新语音房",
  room_name: "room_voice-1",
  owner_id: "user-1",
  member_count: 0,
  visibility: "public" as const,
  group: null,
  group_name: null,
  mine: true,
  created_at: "2026-01-01T00:00:00Z",
};

function renderVoiceCreate(groupId: string | null) {
  const action: FabAction = {
    key: groupId ? "group-voice" : "create-voice",
    label: groupId ? "创建群内语音房" : "创建语音房",
    groupId,
    plannedStep: "F5",
    handler: "voice",
  };
  render(
    <MemoryRouter>
      <CreateFab action={action} />
    </MemoryRouter>,
  );
  fireEvent.click(screen.getByRole("button", { name: action.label }));
  fireEvent.change(screen.getByPlaceholderText("新语音频道名称"), {
    target: { value: "新语音房" },
  });
}

beforeEach(() => {
  useVoiceStore.getState().reset();
});

afterEach(() => {
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
});

describe("语音频道创建浮层", () => {
  it.each([null, "group-1"])("%s 创建成功后关闭弹窗", async (groupId) => {
    vi.mocked(voiceApi.createVoiceChannel).mockResolvedValue({
      ...CHANNEL,
      group: groupId,
      visibility: groupId ? "group" : "public",
    });
    renderVoiceCreate(groupId);

    fireEvent.click(screen.getByRole("button", { name: "建频道" }));

    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: /创建.*语音/ })).not.toBeInTheDocument(),
    );
    expect(voiceApi.createVoiceChannel).toHaveBeenCalledWith(
      "新语音房",
      groupId,
      expect.objectContaining({ visibility: groupId ? "group" : "public" }),
    );
  });

  it.each([null, "group-1"])("%s 创建失败后保留弹窗并显示错误", async (groupId) => {
    vi.mocked(voiceApi.createVoiceChannel).mockRejectedValue(new Error("没有创建权限"));
    renderVoiceCreate(groupId);

    fireEvent.click(screen.getByRole("button", { name: "建频道" }));

    await waitFor(() => expect(screen.getByText("没有创建权限")).toBeInTheDocument());
    expect(screen.getByRole("dialog", { name: /创建.*语音/ })).toBeInTheDocument();
  });
});

export {};
