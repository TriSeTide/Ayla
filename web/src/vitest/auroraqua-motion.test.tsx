import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useTabPanelMotion } from "../hooks/useTabPanelMotion";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";

function mediaPreference(initial = false) {
  let matches = initial;
  const listeners = new Set<() => void>();
  vi.stubGlobal("matchMedia", vi.fn(() => ({
    get matches() { return matches; },
    addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
  })));
  return (reduced: boolean) => {
    matches = reduced;
    act(() => listeners.forEach((listener) => listener()));
  };
}

const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");

function mockAnimation() {
  const cancel = vi.fn();
  const animate = vi.fn(() => ({ cancel }));
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: animate });
  return { animate, cancel };
}

function Panel({ selected, ready = true }: { selected: string; ready?: boolean }) {
  const ref = useTabPanelMotion<HTMLDivElement>(selected, ".content", ready);
  return (
    <div ref={ref}>
      <nav>不参与内容动画的导航</nav>
      <div className="content" data-testid="content"><textarea aria-label="草稿" /></div>
    </div>
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

describe("Auroraqua panel ownership", () => {
  it("只动画现存面板，不重挂载草稿、改变滚动或重播无关更新", () => {
    mediaPreference();
    const { animate, cancel } = mockAnimation();
    const { rerender, unmount } = render(<Panel selected="chat" />);
    const input = screen.getByRole("textbox", { name: "草稿" });
    const content = screen.getByTestId("content");
    fireEvent.change(input, { target: { value: "还没发送的消息" } });
    content.scrollTop = 137;
    expect(animate).not.toHaveBeenCalled();

    rerender(<Panel selected="requests" />);
    expect(animate).toHaveBeenCalledTimes(1);
    expect(animate.mock.contexts[0]).toBe(content);
    expect(screen.getByRole("textbox", { name: "草稿" })).toBe(input);
    expect(input).toHaveValue("还没发送的消息");
    expect(content.scrollTop).toBe(137);
    rerender(<Panel selected="requests" />);
    expect(animate).toHaveBeenCalledTimes(1);
    unmount();
    expect(cancel).toHaveBeenCalledTimes(1);
  });

  it("动态开启 reduced-motion 取消正在运行的动画并禁用后续位移", () => {
    const setReduced = mediaPreference();
    const { animate, cancel } = mockAnimation();
    const { rerender } = render(<Panel selected="chat" />);
    rerender(<Panel selected="requests" />);
    expect(animate).toHaveBeenCalledTimes(1);
    setReduced(true);
    expect(cancel).toHaveBeenCalledTimes(1);
    rerender(<Panel selected="chat" />);
    expect(animate).toHaveBeenCalledTimes(1);
  });

  it("异步筛选等实际内容就绪后才播放，加载中不消耗入场动画", () => {
    mediaPreference();
    const { animate } = mockAnimation();
    const { rerender } = render(<Panel selected="all" />);
    rerender(<Panel selected="post" ready={false} />);
    expect(animate).not.toHaveBeenCalled();
    rerender(<Panel selected="post" ready />);
    expect(animate).toHaveBeenCalledTimes(1);
  });

  it("缺少 Web Animations 时内容仍可用且保持原节点", () => {
    mediaPreference();
    Reflect.deleteProperty(HTMLElement.prototype, "animate");
    const { rerender } = render(<Panel selected="chat" />);
    const content = screen.getByTestId("content");
    rerender(<Panel selected="requests" />);
    expect(screen.getByTestId("content")).toBe(content);
    expect(content.style.opacity).toBe("");
  });
});

describe("room entry preference changes", () => {
  function Room({ active }: { active: boolean }) {
    const { inputEntered } = useEnterRoomAnimation(active);
    return <output>{inputEntered ? "entered" : "waiting"}</output>;
  }

  it("reduced-motion 中止延迟且切回普通模式不重播；离房后再次进入重新等待", () => {
    vi.useFakeTimers();
    const setReduced = mediaPreference();
    const { rerender } = render(<Room active />);
    expect(screen.getByText("waiting")).toBeInTheDocument();
    setReduced(true);
    expect(screen.getByText("entered")).toBeInTheDocument();
    setReduced(false);
    expect(screen.getByText("entered")).toBeInTheDocument();
    rerender(<Room active={false} />);
    expect(screen.getByText("waiting")).toBeInTheDocument();
    rerender(<Room active />);
    expect(screen.getByText("waiting")).toBeInTheDocument();
    act(() => vi.advanceTimersByTime(100));
    expect(screen.getByText("entered")).toBeInTheDocument();
  });
});
