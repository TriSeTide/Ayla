/**
 * VoiceMemberRow 测试（行尾操作区：开关按钮 + 覆盖式音量条 VoiceVolumeMeter）：
 * - 自己的行：行尾 = 麦克风按钮（aria-label 一键禁音/一键恢复）+ 音量条
 *   （轨道 --fill=localVolume 设定音量、跳动条宽度随 localAudioLevel）；
 * - 别人的行：行尾 = 喇叭按钮（aria-label 静音/恢复声音）+ 音量条
 *   （轨道 --fill=member.volume、跳动条宽度随 member.audioLevel）；
 * - 点击按钮回调 onToggleMic / onToggleMemberMuted(user_id)；
 * - 拖动 slider 回调 onLocalVolumeChange / onVolumeChange(user_id, 值)。
 */
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useVoiceStore } from "../stores/voice";
import { VoiceMemberRow } from "../components/voice/VoiceMemberRow";

vi.mock("../api/users", () => ({
  getCachedUser: vi.fn(() => null),
  ensureUser: vi.fn(async () => null),
}));

function member(
  overrides: Partial<{
    user_id: string;
    muted: boolean;
    volume: number;
    audioLevel: number;
    locallyMuted: boolean;
  }> = {},
) {
  return {
    user_id: "u_self",
    joined_at: "2026-01-01T00:00:00Z",
    last_seen_at: "2026-01-01T00:00:00Z",
    muted: false,
    volume: 100,
    audioLevel: 0,
    locallyMuted: false,
    ...overrides,
  };
}

/** 取覆盖跳动条的宽度百分比（解析内联 style） */
function fillWidth(container: HTMLElement): number {
  const fill = container.querySelector(".voice-meter-fill");
  if (!fill) return -1;
  const m = /width:\s*([\d.]+)%/.exec(fill.getAttribute("style") ?? "");
  return m ? Number.parseFloat(m[1]) : -1;
}

/** 取底层轨道填充变量 --fill（设定音量百分比） */
function trackFill(container: HTMLElement): string {
  const track = container.querySelector<HTMLElement>(".voice-meter-track");
  return track?.style.getPropertyValue("--fill") ?? "";
}

beforeEach(() => {
  useVoiceStore.getState().reset();
});

afterEach(() => {
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
});

describe("VoiceMemberRow", () => {
  it("自己的行：行尾 = 麦克风按钮 + 音量条（轨道 --fill=设定音量、跳动随 localAudioLevel）", () => {
    useVoiceStore.getState().setMicEnabled(true); // 默认 reset 后是禁音态
    useVoiceStore.getState().setLocalAudioLevel(0.42);
    useVoiceStore.getState().setLocalVolume(70);
    const { container } = render(
      <VoiceMemberRow
        member={member()}
        isSelf
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={vi.fn()}
      />,
    );

    // 行尾操作区：麦克风按钮（开麦态）+ 音量条
    const toggle = screen.getByRole("button", { name: "一键禁音" });
    expect(toggle).not.toBeNull();
    const slider = screen.getByRole("slider", { name: "我的麦克风音量" });
    expect((slider as HTMLInputElement).value).toBe("70");
    expect(trackFill(container)).toBe("70%");
    // 覆盖跳动条宽度 = 实时音量做非线性放大（0.42^0.4 ≈ 0.7067 → 71%）
    expect(fillWidth(container)).toBe(71);
    // 音量条在行尾操作区（与其他成员同一水平线，上下等距）
    expect(container.querySelector(".voice-member-actions")).not.toBeNull();
  });

  it("自己的行：禁音态按钮显示「一键恢复」，点击调 onToggleMic", () => {
    useVoiceStore.getState().setMicEnabled(false);
    const onToggleMic = vi.fn();
    render(
      <VoiceMemberRow
        member={member()}
        isSelf
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={onToggleMic}
        onToggleMemberMuted={vi.fn()}
      />,
    );

    const toggle = screen.getByRole("button", { name: "一键恢复" });
    expect(toggle.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(toggle);
    expect(onToggleMic).toHaveBeenCalledTimes(1);
  });

  it("自己的行：未开麦（level=0）时跳动条宽度为 0，但轨道仍有 --fill 颜色", () => {
    const { container } = render(
      <VoiceMemberRow
        member={member()}
        isSelf
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={vi.fn()}
      />,
    );
    expect(fillWidth(container)).toBe(0);
    expect(trackFill(container)).toBe("100%"); // 默认音量 100 → 轨道全填充
  });

  it("拖动本地 slider 调 onLocalVolumeChange(值)", () => {
    const onLocalVolumeChange = vi.fn();
    render(
      <VoiceMemberRow
        member={member()}
        isSelf
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={onLocalVolumeChange}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={vi.fn()}
      />,
    );

    const slider = screen.getByRole("slider", { name: "我的麦克风音量" });
    fireEvent.change(slider, { target: { value: "66" } });
    expect(onLocalVolumeChange).toHaveBeenCalledWith(66);
  });

  it("别人的行：行尾 = 喇叭按钮 + 音量条（轨道 --fill=其播放音量、跳动随其说话音量）", () => {
    const { container } = render(
      <VoiceMemberRow
        member={member({ user_id: "u_other", volume: 40, audioLevel: 0.31 })}
        isSelf={false}
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={vi.fn()}
      />,
    );

    const toggle = screen.getByRole("button", { name: /静音/ });
    expect(toggle).not.toBeNull();
    const slider = screen.getByRole("slider", { name: /的音量/ });
    expect((slider as HTMLInputElement).value).toBe("40");
    expect(trackFill(container)).toBe("40%");
    expect(fillWidth(container)).toBe(63); // 说话音量 0.31^0.4 ≈ 0.626 → 63%
  });

  it("别人的行：静音态按钮显示「恢复声音」，点击调 onToggleMemberMuted(user_id)；静音时跳动条归零", () => {
    const onToggleMemberMuted = vi.fn();
    const { container } = render(
      <VoiceMemberRow
        member={member({ user_id: "u_other", locallyMuted: true, audioLevel: 0.9 })}
        isSelf={false}
        isElysia={false}
        onVolumeChange={vi.fn()}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={onToggleMemberMuted}
      />,
    );

    const toggle = screen.getByRole("button", { name: /恢复声音/ });
    expect(toggle.getAttribute("aria-pressed")).toBe("true");
    // 静音时即使他大声说话（audioLevel 0.9），跳动条也归零（静音=不听，说话跳动指示一并停）
    expect(fillWidth(container)).toBe(0);
    fireEvent.click(toggle);
    expect(onToggleMemberMuted).toHaveBeenCalledWith("u_other");
  });

  it("拖动别人的音量滑条调 onVolumeChange(member.user_id, 值)", () => {
    const onVolumeChange = vi.fn();
    render(
      <VoiceMemberRow
        member={member({ user_id: "u_other" })}
        isSelf={false}
        isElysia={false}
        onVolumeChange={onVolumeChange}
        onLocalVolumeChange={vi.fn()}
        onToggleMic={vi.fn()}
        onToggleMemberMuted={vi.fn()}
      />,
    );

    const slider = screen.getByRole("slider", { name: /的音量/ });
    fireEvent.change(slider, { target: { value: "33" } });
    expect(onVolumeChange).toHaveBeenCalledWith("u_other", 33);
  });
});
