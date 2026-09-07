/**
 * PrimaryNavPage 测试（方案 §3.1）：
 * - 渲染 children（复用 .primary-nav-page 布局，absolute 重叠转场）；
 * - direction 决定 Auroraqua 的 enter 初始横滑位移（1 → 右 20px / -1 → 左 20px / 0 → 无位移）；
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

  it("direction=1：沿原导航方向从右侧 20px 滑入", () => {
    renderPage("/voice", 1);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    expect(el.style.transform).toContain("translateX(20px)");
    // 用户可以在入场尚未结束时起手；drag 的原点始终独立于 route 的 20px。
    const drag = el.querySelector(".primary-nav-drag") as HTMLElement;
    expect(drag).toBeInTheDocument();
    expect(drag.style.transform).not.toContain("translateX");
  });

  it("direction=-1：沿原导航方向从左侧 20px 滑入", () => {
    renderPage("/voice", -1);
    const el = document.querySelector(".primary-nav-page") as HTMLElement;
    expect(el.style.transform).toContain("translateX(-20px)");
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
