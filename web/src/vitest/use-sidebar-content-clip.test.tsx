import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Fragment, useRef } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useSidebarContentClip } from "../hooks/useSidebarContentClip";

type Scene = "chat" | "voice" | "live";
type Role = "viewport" | Scene | `${Scene}-content`;
type Box = { top: number; height: number };
const scenes: Scene[] = ["chat", "voice", "live"];
const contentClasses: Record<Scene, string> = {
  chat: "channel-subgroups", voice: "channel-voice-rooms", live: "channel-live-rooms",
};
const NativeMutationObserver = globalThis.MutationObserver;
let boxes: Record<Role, Box>;
let reads: HTMLElement[];
let resizes: ResizeProbe[];
let mutations: MutationProbe[];

class ResizeProbe {
  readonly targets = new Set<Element>();
  observe = vi.fn((target: Element) => { this.targets.add(target); });
  unobserve = vi.fn((target: Element) => { this.targets.delete(target); });
  disconnect = vi.fn(() => { this.targets.clear(); });
  constructor(private readonly callback: ResizeObserverCallback) { resizes.push(this); }
  emit() { this.callback([], this as unknown as ResizeObserver); }
}

class MutationProbe {
  private readonly native: MutationObserver;
  observe = vi.fn((target: Node, options?: MutationObserverInit) => this.native.observe(target, options));
  disconnect = vi.fn(() => this.native.disconnect());
  takeRecords = () => this.native.takeRecords();
  constructor(private readonly callback: MutationCallback) {
    this.native = new NativeMutationObserver((records) => callback(records, this as unknown as MutationObserver));
    mutations.push(this);
  }
  emitRetiredCallback() { this.callback([], this as unknown as MutationObserver); }
}

beforeEach(() => {
  boxes = {
    viewport: { top: 100, height: 504 },
    chat: { top: 102, height: 40 },
    voice: { top: 510, height: 40 },
    live: { top: 554, height: 40 },
    "chat-content": { top: 146, height: 640 },
    "voice-content": { top: 834, height: 200 },
    "live-content": { top: 1082, height: 160 },
  };
  reads = [];
  resizes = [];
  mutations = [];
  vi.stubGlobal("ResizeObserver", ResizeProbe);
  vi.stubGlobal("MutationObserver", MutationProbe);
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    const box = boxes[this.dataset.clipRole as Role];
    if (!box) return new DOMRect();
    reads.push(this);
    return new DOMRect(24, box.top, 260, box.height);
  });
  vi.spyOn(HTMLElement.prototype, "clientTop", "get").mockImplementation(function (this: HTMLElement) {
    return this.dataset.clipRole === "viewport" ? 2 : 0;
  });
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockImplementation(function (this: HTMLElement) {
    return this.dataset.clipRole === "viewport" ? boxes.viewport.height - 4 : 0;
  });
  vi.spyOn(HTMLElement.prototype, "scrollHeight", "get").mockImplementation(function (this: HTMLElement) {
    return this.dataset.clipRole === "viewport" ? 2400 : 0;
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function Sidebar({ shown = scenes }: { shown?: Scene[] }) {
  const ref = useRef<HTMLDivElement>(null);
  useSidebarContentClip(ref);
  return <div ref={ref} data-testid="viewport" data-clip-role="viewport" style={{ rowGap: "4px", overflowY: "auto" }}>
    {scenes.map((scene) => <Fragment key={scene}>
      <div className={`channel-scene-row channel-scene-row--${scene}`} data-clip-role={scene} data-testid={scene}>
        <button>{scene}</button>
      </div>
      {shown.includes(scene) && <div className={contentClasses[scene]} data-clip-role={`${scene}-content`}
        data-testid={`${scene}-content`} style={{ height: "auto", overflow: "hidden" }}>
        <ul><li data-testid={`${scene}-room`} style={{ transform: "translateY(-180px)" }}>
          <button>{scene} room</button>
        </li></ul>
      </div>}
    </Fragment>)}
  </div>;
}

function insets(node: HTMLElement) {
  const match = /^inset\(([-\d.]+)px 0px ([-\d.]+)px 0px\)$/.exec(node.style.clipPath);
  expect(match, `Expected a finite vertical paint clip on ${node.dataset.clipRole}`).not.toBeNull();
  const top = Number(match![1]), bottom = Number(match![2]);
  expect(Number.isFinite(top) && Number.isFinite(bottom)).toBe(true);
  expect(top).toBeGreaterThanOrEqual(0);
  expect(bottom).toBeGreaterThanOrEqual(0);
  return { top, bottom };
}

function expectVisible(scene: Scene, expectedTop: number, expectedBottom: number) {
  const box = boxes[`${scene}-content`];
  const { top, bottom } = insets(screen.getByTestId(`${scene}-content`));
  expect(box.top + top).toBe(expectedTop);
  expect(box.top + box.height - bottom).toBe(expectedBottom);
}

function expectHidden(scene: Scene) {
  const { top, bottom } = insets(screen.getByTestId(`${scene}-content`));
  expect(top + bottom).toBe(boxes[`${scene}-content`].height);
}

describe("侧栏内容只在实际吸顶/吸底标题之间绘制", () => {
  it("后两标题吸底时只截断长子群列表，保留其完整滚动高度", () => {
    render(<Sidebar />);
    expectVisible("chat", 146, 506);
    expectHidden("voice");
    expectHidden("live");
    expect(screen.getByTestId("viewport").scrollHeight).toBe(2400);
    for (const scene of scenes) expect(screen.getByTestId(scene).style.clipPath).toBe("");
  });

  it("标题逐个吸顶后清空4px标题缝，末段按scrollport内边缘裁剪", () => {
    boxes.voice = { top: 146, height: 40 };
    boxes.live = { top: 190, height: 40 };
    boxes["chat-content"] = { top: -100, height: 400 };
    boxes["voice-content"] = { top: 40, height: 650 };
    boxes["live-content"] = { top: 120, height: 900 };
    render(<Sidebar />);
    expectHidden("chat");
    expectHidden("voice");
    expectVisible("live", 234, 602);
  });

  it.each([
    { top: -300, height: 40 },
    { top: 900, height: 40 },
    { top: 150, height: 0 },
  ])("完全离开可见带或零高度不产生负数/反向窗口：%j", (box) => {
    boxes["chat-content"] = box;
    render(<Sidebar />);
    expectHidden("chat");
  });

  it("自然流内容不额外缩短；scroll更新裁剪但不接管滚动、行transform或DOM", () => {
    boxes["chat-content"] = { top: 146, height: 196 };
    boxes.voice = { top: 346, height: 40 };
    render(<Sidebar />);
    expectVisible("chat", 146, 342);
    const root = screen.getByTestId("viewport");
    const row = screen.getByTestId("chat-room");
    const dropdown = screen.getByTestId("chat-content");
    root.scrollTop = 378;
    boxes["chat-content"] = { top: 46, height: 496 };
    boxes.voice = { top: 410, height: 40 };
    fireEvent.scroll(root);
    expectVisible("chat", 146, 406);
    expect(root.scrollTop).toBe(378);
    expect(root.scrollHeight).toBe(2400);
    expect(screen.getByTestId("chat-room")).toBe(row);
    expect(row.style.transform).toBe("translateY(-180px)");
    expect(dropdown.style.height).toBe("auto");
    expect(dropdown.style.overflow).toBe("hidden");
    expect(row.querySelector("button")).not.toHaveAttribute("tabindex");
  });

  it("展开高度与scrollport resize改变后，既有观察器刷新实际可见窗口", () => {
    render(<Sidebar />);
    boxes.voice = { top: 402, height: 40 };
    boxes.live = { top: 446, height: 40 };
    boxes.viewport.height = 396;
    act(() => resizes[0].emit());
    expectVisible("chat", 146, 398);
    expect(resizes[0].targets.has(screen.getByTestId("chat-content"))).toBe(true);
    expect(resizes[0].targets.has(screen.getByTestId("viewport"))).toBe(true);
  });

  it("React增删下拉时新节点立即受保护，旧节点和旧观察器释放", () => {
    const { rerender } = render(<Sidebar shown={["chat"]} />);
    const oldContent = screen.getByTestId("chat-content");
    const oldResize = resizes[0], oldMutation = mutations[0];
    boxes.voice = { top: 146, height: 40 };
    boxes["voice-content"] = { top: 190, height: 640 };
    rerender(<Sidebar shown={["voice"]} />);
    expect(oldContent.style.clipPath).toBe("");
    expect(oldResize.disconnect).toHaveBeenCalledTimes(1);
    expect(oldMutation.disconnect).toHaveBeenCalledTimes(1);
    expectVisible("voice", 190, 550);
    expect(resizes[resizes.length - 1].targets.has(screen.getByTestId("voice-content"))).toBe(true);
  });

  it("AnimatePresence内部移走零高度节点后按消失的flex gap更新，且不观察style/subtree", async () => {
    boxes["chat-content"].height = 0;
    boxes.voice = { top: 150, height: 40 };
    boxes["voice-content"] = { top: 194, height: 640 };
    render(<Sidebar />);
    const removed = screen.getByTestId("chat-content");
    const root = screen.getByTestId("viewport");
    expectVisible("voice", 194, 550);
    await act(async () => {
      boxes.voice.top -= 4;
      boxes["voice-content"].top -= 4;
      removed.remove();
      await Promise.resolve();
    });
    expectVisible("voice", 190, 550);
    expect(removed.style.clipPath).toBe("");
    expect(resizes[0].targets.has(removed)).toBe(false);
    expect(mutations[0].observe).toHaveBeenCalledWith(root, { childList: true });
    const readsBefore = reads.length;
    await act(async () => {
      screen.getByTestId("voice-room").style.transform = "translateY(-93px)";
      await Promise.resolve();
    });
    expect(reads.length).toBe(readsBefore);
  });

  it("卸载清理仅移除自己最后写入的clip，移除监听并拒绝迟到观察回调", () => {
    const { unmount } = render(<Sidebar />);
    const root = screen.getByTestId("viewport");
    const chat = screen.getByTestId("chat-content");
    const live = screen.getByTestId("live-content");
    live.style.clipPath = "circle(40%)";
    unmount();
    expect(chat.style.clipPath).toBe("");
    expect(live.style.clipPath).toBe("circle(40%)");
    expect(resizes[0].disconnect).toHaveBeenCalledTimes(1);
    expect(mutations[0].disconnect).toHaveBeenCalledTimes(1);
    const readsAfterUnmount = reads.length;
    boxes.voice.top -= 44;
    boxes.live.top -= 44;
    fireEvent.scroll(root);
    act(() => {
      resizes[0].emit();
      mutations[0].emitRetiredCallback();
    });
    expect(reads.length).toBe(readsAfterUnmount);
    expect(chat.style.clipPath).toBe("");
    expect(live.style.clipPath).toBe("circle(40%)");
  });
});
