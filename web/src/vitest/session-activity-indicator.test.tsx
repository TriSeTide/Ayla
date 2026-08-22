/**
 * SessionActivityIndicator 组件契约测试。
 *
 * - 无活动语音/直播会话 → 不渲染任何浮层；
 * - 语音会话进行中 → 渲染语音球 + 收起把手；
 * - 点击收起把手 → 容器进入 is-collapsed（CSS 半贴边动画态）、
 *   aria-label 切换为「展开媒体控制」；再次点击恢复展开。
 */
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionActivityIndicator } from "../layout/SessionActivityIndicator";

const voiceUser = {
  id: "u1",
  is_in_voice: true,
  voice_room_id: 5,
  is_live: false,
  live_room_id: null,
};

/** 测试内可切换的当前用户（null = 无任何媒体活动态）。 */
let mockCurrentUser: typeof voiceUser | null = voiceUser;

vi.mock("../stores/auth", () => ({
  useAuthStore: (selector: (s: { currentUser: typeof voiceUser | null }) => unknown) =>
    selector({ currentUser: mockCurrentUser }),
}));

vi.mock("../stores/sessionActivity", () => ({
  useSessionActivityStore: (selector: (s: { voiceSession: null; liveSession: null }) => unknown) =>
    selector({ voiceSession: null, liveSession: null }),
}));

function renderIndicator() {
  return render(
    <MemoryRouter initialEntries={["/home"]}>
      <SessionActivityIndicator />
    </MemoryRouter>,
  );
}

afterEach(() => {
  vi.clearAllMocks();
  mockCurrentUser = voiceUser;
});

describe("SessionActivityIndicator", () => {
  it("无活动会话时不渲染浮层", () => {
    mockCurrentUser = null;
    const { container } = renderIndicator();
    expect(container).toBeEmptyDOMElement();
  });

  it("语音会话进行中渲染语音球与收起把手", () => {
    renderIndicator();
    expect(screen.getByRole("button", { name: "返回语音房" })).toBeInTheDocument();
    const toggle = screen.getByRole("button", { name: "收起媒体控制" });
    expect(toggle).toHaveAttribute("aria-expanded", "true");
  });

  it("点击收起把手：球收起隐藏、把手贴边待恢复；再次点击还原三钮", () => {
    renderIndicator();
    const group = document.querySelector(".session-activity-group");
    expect(group).not.toBeNull();
    expect(group!.classList.contains("is-collapsed")).toBe(false);
    expect(screen.getByRole("button", { name: "返回语音房" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "收起媒体控制" }));
    // is-collapsed 驱动 CSS 贴边动画（球的滑出淡隐/隐藏由 shell.css 承载）
    expect(group!.classList.contains("is-collapsed")).toBe(true);
    const expandedToggle = screen.getByRole("button", { name: "展开媒体控制" });
    expect(expandedToggle).toHaveAttribute("aria-expanded", "false");

    fireEvent.click(expandedToggle);
    expect(group!.classList.contains("is-collapsed")).toBe(false);
    expect(screen.getByRole("button", { name: "返回语音房" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "收起媒体控制" })).toHaveAttribute("aria-expanded", "true");
  });
});
