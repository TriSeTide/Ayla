import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BottomTabs } from "../layout/BottomTabs";
import { GroupTopTabs } from "../components/group/GroupTopTabs";

// Inspect the projection ownership prop; layout geometry is verified in the browser.
vi.mock("framer-motion", () => ({
  motion: {
    span: ({ layoutId }: { layoutId?: string }) => (
      <span className="auroraqua-nav-highlight" aria-hidden="true" data-projection-owner={layoutId} />
    ),
  },
}));

afterEach(() => vi.unstubAllGlobals());

describe("Auroraqua selection surfaces", () => {
  it("窄屏群导航保留五个入口和当前tab高亮，移除额外的五圆点行", () => {
    const onSelectScene = vi.fn();
    render(<GroupTopTabs groupName="测试群" activeScene="voice" onSelectScene={onSelectScene} onAvatarClick={() => {}} />);
    expect(screen.getAllByRole("button")).toHaveLength(5);
    expect(screen.getByRole("button", { name: "语音" })).toHaveAttribute("aria-current", "true");
    expect(screen.getByRole("button", { name: "群头像：测试群" })).toBeInTheDocument();
    expect(document.querySelector(".group-top-dots")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "桌游" }));
    expect(onSelectScene).toHaveBeenCalledWith("games");
  });

  it("切换高亮保留原链接、可访问名称、未读徽标和导航实例边界", () => {
    const { rerender } = render(
      <MemoryRouter>
        <BottomTabs moduleKey="voice" badges={{ live: 7 }} />
        <BottomTabs moduleKey="posts" />
      </MemoryRouter>,
    );
    const highlights = document.querySelectorAll<HTMLElement>(".auroraqua-nav-highlight");
    expect(highlights).toHaveLength(2);
    expect(highlights[0].dataset.projectionOwner).not.toBe(highlights[1].dataset.projectionOwner);
    const owner = highlights[0].dataset.projectionOwner;
    expect(highlights[0].closest("a")).toHaveAttribute("href", "/voice");
    expect(screen.getByLabelText("7 条未读")).toBeInTheDocument();
    rerender(<MemoryRouter><BottomTabs moduleKey="live" badges={{ live: 7 }} /><BottomTabs moduleKey="posts" /></MemoryRouter>);
    const current = document.querySelector<HTMLElement>(".auroraqua-nav-highlight")!;
    expect(current.dataset.projectionOwner).toBe(owner);
    expect(current.closest("a")).toHaveAttribute("href", "/live");
    expect(current.closest("a")).toHaveAttribute("aria-current", "page");
    expect(screen.getAllByRole("link")).toHaveLength(10);
  });

  it("偏好在当前页改变时移除共享几何动画，保留选中反馈", () => {
    let matches = false;
    const listeners = new Set<() => void>();
    vi.stubGlobal("matchMedia", vi.fn(() => ({
      get matches() { return matches; },
      addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
    })));
    render(<MemoryRouter><BottomTabs moduleKey="voice" /></MemoryRouter>);
    expect(document.querySelector("[data-projection-owner]")).not.toBeNull();
    act(() => { matches = true; listeners.forEach((listener) => listener()); });
    expect(document.querySelector("[data-projection-owner]")).toBeNull();
    expect(document.querySelector(".auroraqua-nav-highlight")?.closest("a")).toHaveAttribute("aria-current", "page");
  });
});
