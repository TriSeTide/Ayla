/**
 * PrimaryNavPage 测试（方案 §3.1）：
 * - 渲染 children（复用 .primary-nav-page 布局，absolute 重叠转场）；
 * - direction 决定 enter 初始横滑位移（1 → 右 40% / -1 → 左 40% / 0 → 无位移）；
 * - prefers-reduced-motion 降级为纯透明度（无 translateX）。
 *   跟手位移与松手切换由 Playwright TouchEvent 真实验收，单测只覆盖可同步断言的静态分支。
 */
import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PrimaryNavPage } from "../components/motion/PrimaryNavPage";

function renderPage(pathname: string, direction: 1 | -1 | 0) {
  return render(
    <PrimaryNavPage pathname={pathname} direction={direction} onNavigate={() => {}}>
      <div>一级页内容</div>
    </PrimaryNavPage>,
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("PrimaryNavPage", () => {
  it("渲染 children（复用 .primary-nav-page 布局）", () => {
    renderPage("/voice", 0);
    expect(screen.getByText("一级页内容")).toBeInTheDocument();
    expect(document.querySelector(".primary-nav-page")).toBeInTheDocument();
  });

  it("direction=1：enter 初始自右侧 40% 滑入（translateX(40%)）", () => {
    renderPage("/voice", 1);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    expect(el.style.transform).toContain("translateX(40%)");
  });

  it("direction=-1：enter 初始自左侧 40% 滑入（translateX(-40%)）", () => {
    renderPage("/voice", -1);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    expect(el.style.transform).toContain("translateX(-40%)");
  });

  it("direction=0：enter 无横向位移（transform 不含 translateX）", () => {
    renderPage("/voice", 0);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    expect(el.style.transform).not.toContain("translateX");
  });

  it("prefers-reduced-motion：降级为纯透明度（enter 无 translateX）", () => {
    vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: true }) as MediaQueryList));
    renderPage("/voice", 1);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    // reduced-motion 变体只留 opacity，无 x 位移
    expect(el.style.transform).not.toContain("translateX");
  });
});
