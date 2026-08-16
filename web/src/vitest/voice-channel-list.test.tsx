/**
 * VoiceChannelList 测试（测试报告 #1 修复）：
 * - "我在其中"（mine）频道按钮文案「进入」，其余「加入」；
 * - 卡片整体可点击进房（点击/键盘 Enter/Space）；
 * - 按钮点击不冒泡触发卡片点击（只触发一次 onJoin）；
 * - joining 中禁用（按钮 disabled + 卡片 aria-disabled）。
 */
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { VoiceChannelDescriptor } from "../api/types";
import { VoiceChannelList } from "../components/voice/VoiceChannelList";

function ch(id: string, overrides: Partial<VoiceChannelDescriptor> = {}): VoiceChannelDescriptor {
  return {
    id,
    name: `频道${id}`,
    room_name: `room_${id}`,
    owner_id: "o1",
    member_count: 2,
    visibility: "public",
    group: null,
    group_name: null,
    mine: false,
    created_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("VoiceChannelList 进房语义（#1）", () => {
  it("mine 频道按钮文案「进入」，非 mine 为「加入」", () => {
    render(
      <VoiceChannelList
        channels={[ch("v1", { mine: true }), ch("v2")]}
        currentChannelId={null}
        joining={false}
        onJoin={vi.fn()}
      />,
    );
    expect(screen.getByRole("button", { name: "进入" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "加入" })).toBeInTheDocument();
  });

  it("mine 频道显示「我在其中」标签，卡片 aria-label 为「进入语音频道」", () => {
    render(
      <VoiceChannelList
        channels={[ch("v1", { mine: true })]}
        currentChannelId={null}
        joining={false}
        onJoin={vi.fn()}
      />,
    );
    expect(screen.getByText("我在其中")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "进入语音频道 频道v1" })).toBeInTheDocument();
  });

  it("点击卡片整体触发进房（onJoin 传入频道 id）", () => {
    const onJoin = vi.fn();
    render(
      <VoiceChannelList
        channels={[ch("v1")]}
        currentChannelId={null}
        joining={false}
        onJoin={onJoin}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "加入语音频道 频道v1" }));
    expect(onJoin).toHaveBeenCalledTimes(1);
    expect(onJoin).toHaveBeenCalledWith("v1");
  });

  it("点按钮进房且不冒泡（只触发一次 onJoin）", () => {
    const onJoin = vi.fn();
    render(
      <VoiceChannelList
        channels={[ch("v1")]}
        currentChannelId={null}
        joining={false}
        onJoin={onJoin}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "加入" }));
    expect(onJoin).toHaveBeenCalledTimes(1);
    expect(onJoin).toHaveBeenCalledWith("v1");
  });

  it("键盘 Enter / Space 触发进房", () => {
    const onJoin = vi.fn();
    render(
      <VoiceChannelList
        channels={[ch("v1")]}
        currentChannelId={null}
        joining={false}
        onJoin={onJoin}
      />,
    );
    const card = screen.getByRole("button", { name: "加入语音频道 频道v1" });
    fireEvent.keyDown(card, { key: "Enter" });
    fireEvent.keyDown(card, { key: " " });
    expect(onJoin).toHaveBeenCalledTimes(2);
  });

  it("joining 中按钮禁用 + 卡片 aria-disabled，点击不重复触发", () => {
    const onJoin = vi.fn();
    render(
      <VoiceChannelList
        channels={[ch("v1")]}
        currentChannelId={null}
        joining
        onJoin={onJoin}
      />,
    );
    const btn = screen.getByRole("button", { name: "加入中…" }) as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
    // 卡片 aria-disabled；点击卡片也不触发
    const card = screen.getByRole("button", { name: "加入语音频道 频道v1" });
    expect(card.getAttribute("aria-disabled")).toBe("true");
    fireEvent.click(card);
    expect(onJoin).not.toHaveBeenCalled();
  });
});
