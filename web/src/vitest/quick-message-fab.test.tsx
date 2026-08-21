/**
 * QuickMessageFab —— 红点快捷按钮半贴交互测试（R-QM）。
 *
 * - 初始展开，点击就地打开快捷消息栏（mock QuickMessagesSheet）；
 * - 展开态 4s 无点击 → 侧边半贴（aria-label 变「展开消息」）；
 * - 半贴态点击「点出来」展开（不打开快捷栏），再点打开快捷栏。
 */
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { QuickMessageFab } from "../layout/QuickMessageFab";

vi.mock("../components/chat/QuickMessagesSheet", () => ({
  QuickMessagesSheet: ({ onClose }: { onClose: () => void }) => (
    <div data-testid="quick-messages-sheet" onClick={onClose} />
  ),
}));

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("QuickMessageFab 半贴交互", () => {
  it("初始展开，点击打开快捷消息栏", () => {
    render(<QuickMessageFab unread={2} />);
    const btn = screen.getByRole("button", { name: "消息，2 条未读" });
    expect(btn).not.toHaveClass("is-collapsed");
    fireEvent.click(btn);
    expect(screen.getByTestId("quick-messages-sheet")).toBeInTheDocument();
  });

  it("4s 无点击自动半贴，点一下展开（不打开快捷栏）", () => {
    render(<QuickMessageFab unread={2} />);
    expect(screen.getByRole("button", { name: "消息，2 条未读" })).toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(4000);
    });

    // 半贴态：aria-label 变「展开消息」+ is-collapsed
    const collapsedBtn = screen.getByRole("button", { name: "展开消息" });
    expect(collapsedBtn).toHaveClass("is-collapsed");

    // 点一下 → 点出来（展开），不打开快捷栏
    fireEvent.click(collapsedBtn);
    expect(screen.getByRole("button", { name: "消息，2 条未读" })).toBeInTheDocument();
    expect(screen.queryByTestId("quick-messages-sheet")).not.toBeInTheDocument();
  });

  it("半贴 → 点出来 → 再点 → 打开快捷栏", () => {
    render(<QuickMessageFab unread={2} />);
    act(() => {
      vi.advanceTimersByTime(4000);
    });
    fireEvent.click(screen.getByRole("button", { name: "展开消息" })); // 点出来
    fireEvent.click(screen.getByRole("button", { name: "消息，2 条未读" })); // 打开
    expect(screen.getByTestId("quick-messages-sheet")).toBeInTheDocument();
  });
});
