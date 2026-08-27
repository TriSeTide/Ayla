/**
 * 右下角浮层按钮组（方案 §3.4）测试：
 * - shell store registerRefresh 注册/清除；
 * - RefreshFab：点击调用注册回调 + spinning 态、无回调不调用；
 * - ScrollTopFab：页面根滚动超过一屏浮入、点击平滑回顶（reduced-motion 直切）；
 * - CornerFabStack：垂直堆叠承载 ScrollTopFab + RefreshFab。
 *
 * 注意：ScrollTopFab 隐藏态用 aria-hidden=true（从 accessibility tree 移除，accessible
 * name 会被清空），故用 class 选择器定位而非 getByRole 的 name 匹配。
 */
import { act, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CornerFabStack } from "../layout/CornerFabStack";
import { RefreshFab } from "../layout/RefreshFab";
import { ScrollTopFab } from "../layout/ScrollTopFab";
import { useShellStore } from "../stores/shell";

function stubMatchMedia(reduced = false) {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      matches: reduced,
      media: "",
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  );
}

function scrollTopBtn(): HTMLElement {
  const el = document.querySelector(".corner-fab-scroll-top");
  if (!el) throw new Error("ScrollTopFab 未渲染");
  return el as HTMLElement;
}

beforeEach(() => {
  useShellStore.setState({ refreshCallback: null });
  stubMatchMedia(false);
});

afterEach(() => {
  useShellStore.setState({ refreshCallback: null });
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("shell store registerRefresh", () => {
  it("注册与清除当前页刷新回调", () => {
    const fn = vi.fn();
    useShellStore.getState().registerRefresh(fn);
    expect(useShellStore.getState().refreshCallback).toBe(fn);
    useShellStore.getState().registerRefresh(null);
    expect(useShellStore.getState().refreshCallback).toBeNull();
  });
});

describe("RefreshFab", () => {
  it("点击调用注册回调，刷新期间进入 spinning，完成后退出", async () => {
    let resolve!: () => void;
    const fn = vi.fn(() => new Promise<void>((r) => (resolve = r)));
    useShellStore.getState().registerRefresh(fn);
    render(<RefreshFab />);

    const btn = screen.getByRole("button", { name: "刷新当前页" });
    fireEvent.click(btn);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(btn.className).toContain("is-spinning");

    await act(async () => {
      resolve();
    });
    expect(btn.className).not.toContain("is-spinning");
  });

  it("无回调时点击不调用、不进入 spinning（保持纯外观职责）", () => {
    render(<RefreshFab />);
    const btn = screen.getByRole("button", { name: "刷新当前页" });
    fireEvent.click(btn);
    expect(btn.className).not.toContain("is-spinning");
  });
});

describe("ScrollTopFab", () => {
  function renderWithScroller() {
    render(
      <MemoryRouter>
        <div className="page-transition">
          <div data-testid="scroller" />
        </div>
        <ScrollTopFab />
      </MemoryRouter>,
    );
    return screen.getByTestId<HTMLElement>("scroller");
  }

  function makeScroller(scrollTop: number) {
    const scroller = renderWithScroller();
    Object.defineProperty(scroller, "scrollTop", { value: scrollTop, configurable: true });
    // isMainScroller 需可滚动（scrollHeight > clientHeight）且占主体（clientHeight ≥ 40% 视口）
    Object.defineProperty(scroller, "scrollHeight", { value: 2000, configurable: true });
    Object.defineProperty(scroller, "clientHeight", { value: 800, configurable: true });
    return scroller;
  }

  it("初始隐藏（aria-hidden=true + tabIndex=-1，不进入 tab 序）", () => {
    renderWithScroller();
    const btn = scrollTopBtn();
    expect(btn.getAttribute("aria-hidden")).toBe("true");
    expect(btn.getAttribute("tabindex")).toBe("-1");
    expect(btn.className).not.toContain("is-visible");
  });

  it("页面根滚动超过一屏后浮入（aria-hidden=false + is-visible）", () => {
    // jsdom 默认 innerHeight=768，scrollTop 1000 > 768 视为超过一屏
    const scroller = makeScroller(1000);
    act(() => {
      fireEvent.scroll(scroller);
    });
    const btn = scrollTopBtn();
    expect(btn.getAttribute("aria-hidden")).toBe("false");
    expect(btn.className).toContain("is-visible");
  });

  it("未超过一屏不浮入", () => {
    const scroller = makeScroller(100);
    act(() => {
      fireEvent.scroll(scroller);
    });
    expect(scrollTopBtn().getAttribute("aria-hidden")).toBe("true");
  });

  it("小的内嵌子滚动区（clientHeight 不占主体）不触发浮入", () => {
    render(
      <MemoryRouter>
        <div className="page-transition">
          <div>
            <div data-testid="inner" />
          </div>
        </div>
        <ScrollTopFab />
      </MemoryRouter>,
    );
    const inner = screen.getByTestId<HTMLElement>("inner");
    Object.defineProperty(inner, "scrollTop", { value: 1000, configurable: true });
    Object.defineProperty(inner, "scrollHeight", { value: 2000, configurable: true });
    // 小滚动区：clientHeight 200 < 40% 视口（768*0.4≈307），不判为主滚动容器
    Object.defineProperty(inner, "clientHeight", { value: 200, configurable: true });
    act(() => {
      fireEvent.scroll(inner);
    });
    expect(scrollTopBtn().getAttribute("aria-hidden")).toBe("true");
  });

  it("点击回顶：默认平滑滚动", () => {
    const scroller = makeScroller(1000);
    const scrollTo = vi.fn();
    scroller.scrollTo = scrollTo;
    act(() => {
      fireEvent.scroll(scroller);
    });
    fireEvent.click(scrollTopBtn());
    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" });
  });

  it("点击回顶：reduced-motion 直切（behavior=auto）", () => {
    stubMatchMedia(true);
    const scroller = makeScroller(1000);
    const scrollTo = vi.fn();
    scroller.scrollTo = scrollTo;
    act(() => {
      fireEvent.scroll(scroller);
    });
    fireEvent.click(scrollTopBtn());
    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "auto" });
  });
});

describe("CornerFabStack", () => {
  it("垂直堆叠承载 ScrollTopFab + RefreshFab（对换后：回顶在上、刷新在下）", () => {
    render(
      <MemoryRouter>
        <CornerFabStack refresh scrollTop />
      </MemoryRouter>,
    );
    const stack = document.querySelector(".corner-fab-stack");
    expect(stack).not.toBeNull();
    const buttons = stack!.querySelectorAll("button.corner-fab");
    expect(buttons).toHaveLength(2);
    // 对换后 DOM 顺序（flex column 从上到下）：回顶（上）、刷新（下）
    expect(buttons[0].className).toContain("corner-fab-scroll-top");
    expect(buttons[1].className).toContain("corner-fab-refresh");
    expect(screen.getByRole("button", { name: "刷新当前页" })).toBeInTheDocument();
    expect(document.querySelector(".corner-fab-scroll-top")).not.toBeNull();
  });

  it("只显示回顶键时不渲染刷新键（窄屏场景）", () => {
    render(
      <MemoryRouter>
        <CornerFabStack refresh={false} scrollTop />
      </MemoryRouter>,
    );
    expect(document.querySelector(".corner-fab-scroll-top")).not.toBeNull();
    expect(document.querySelector(".corner-fab-refresh")).toBeNull();
  });
});
