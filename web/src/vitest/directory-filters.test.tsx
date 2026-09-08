import { useState } from "react";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DirectoryFilters } from "../components/DirectoryFilters";

vi.mock("../components/motion/AuroraquaNavHighlight", () => ({ AuroraquaNavHighlight: () => null }));

const options = [
  { key: "all", label: "全部" }, { key: "user", label: "用户" },
  { key: "group", label: "群聊" }, { key: "post", label: "帖子" },
  { key: "live", label: "直播间" }, { key: "voice", label: "语音房" },
  { key: "game", label: "桌游室" },
] as const;

function Harness({ narrow = true }: { narrow?: boolean }) {
  const [value, setValue] = useState<(typeof options)[number]["key"]>("all");
  return <>
    <DirectoryFilters id="filters" label="目录分类" options={options} value={value} narrow={narrow} onChange={setValue} />
    <div id="filters-panel" role="tabpanel" aria-labelledby={`filters-${value}`} />
  </>;
}

function horizontalGeometry() {
  const list = screen.getByRole("tablist");
  let width = 375;
  Object.defineProperties(list, {
    clientWidth: { configurable: true, get: () => width },
    clientHeight: { configurable: true, value: 61 },
  });
  list.style.scrollPaddingInlineStart = "12px";
  vi.spyOn(list, "getBoundingClientRect").mockImplementation(() => new DOMRect(0, 56, width, 61));
  screen.getAllByRole("tab").forEach((tab, index) => {
    vi.spyOn(tab, "getBoundingClientRect").mockImplementation(() => new DOMRect(12 + index * 80 - list.scrollLeft, 64, 72, 44));
  });
  return { list, resize: (next: number) => { width = next; } };
}

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("DirectoryFilters scroll and input boundaries", () => {
  it("宽屏装饰图标不成为选项卡且不拦截交互", () => {
    render(
      <div data-testid="decor-wrap">
        <DirectoryFilters id="decor-filters" label="目录分类" options={options} value="all" narrow={false}
          onChange={() => undefined}
          decor={<svg data-testid="decor-icon" aria-hidden="true" />} />
      </div>,
    );
    expect(screen.getByTestId("decor-icon")).toBeInTheDocument();
    expect(screen.getByTestId("decor-icon").closest("[role=tab]")).toBeNull();
    expect(screen.getAllByRole("tab")).toHaveLength(options.length);
    expect(screen.getByTestId("decor-icon")).toHaveAttribute("aria-hidden", "true");
  });

  it("End/Home keep the focused category visible without moving results", () => {
    render(<Harness />);
    const { list } = horizontalGeometry();
    const results = screen.getByRole("tabpanel");
    results.scrollTop = 137;
    const first = screen.getByRole("tab", { name: "全部" });
    first.focus();
    fireEvent.keyDown(first, { key: "End" });
    const last = screen.getByRole("tab", { name: "桌游室" });
    expect(last).toHaveFocus();
    expect(last).toHaveAttribute("aria-selected", "true");
    expect(last).toHaveAttribute("aria-controls", results.id);
    expect(list.scrollLeft).toBeGreaterThan(0);
    expect(last.getBoundingClientRect().right).toBeLessThanOrEqual(list.clientWidth - 12);
    expect(results.scrollTop).toBe(137);
    fireEvent.keyDown(last, { key: "Home" });
    expect(first).toHaveFocus();
    expect(first.getBoundingClientRect().left).toBeGreaterThanOrEqual(12);
    expect(list.scrollLeft).toBe(0);
    expect(results.scrollTop).toBe(137);
  });

  it("keeps the selected category visible after the strip becomes narrower", () => {
    const observers: { callback: () => void; disconnect: ReturnType<typeof vi.fn> }[] = [];
    vi.stubGlobal("ResizeObserver", class {
      disconnect = vi.fn();
      constructor(callback: () => void) { observers.push({ callback, disconnect: this.disconnect }); }
      observe() {}
    });
    const view = render(<Harness />);
    const { list, resize } = horizontalGeometry();
    fireEvent.keyDown(screen.getByRole("tab", { name: "全部" }), { key: "End" });
    const previousScroll = list.scrollLeft;
    resize(200);
    act(() => observers.at(-1)!.callback());
    expect(list.scrollLeft).toBeGreaterThan(previousScroll);
    expect(screen.getByRole("tab", { name: "桌游室" }).getBoundingClientRect().right).toBeLessThanOrEqual(188);
    view.unmount();
    expect(observers.every(observer => observer.disconnect.mock.calls.length > 0)).toBe(true);
  });

  it.each([true, false])("isolates native narrow swipes while preserving click selection (narrow=%s)", (narrow) => {
    const parentTouch = vi.fn(), parentPointer = vi.fn();
    render(<div onTouchStart={parentTouch} onTouchMove={parentTouch} onTouchEnd={parentTouch} onTouchCancel={parentTouch}
      onPointerDown={parentPointer}><Harness narrow={narrow} /></div>);
    const tab = screen.getByRole("tab", { name: "语音房" });
    expect(fireEvent.touchStart(tab, { touches: [{ clientX: 250, clientY: 80 }] })).toBe(true);
    expect(fireEvent.touchMove(tab, { touches: [{ clientX: 80, clientY: 80 }] })).toBe(true);
    expect(fireEvent.touchEnd(tab, { changedTouches: [{ clientX: 80, clientY: 80 }] })).toBe(true);
    fireEvent.touchCancel(tab);
    fireEvent.pointerDown(tab);
    expect(parentTouch).toHaveBeenCalledTimes(narrow ? 0 : 4);
    expect(parentPointer).toHaveBeenCalledTimes(narrow ? 0 : 1);
    fireEvent.click(tab);
    expect(tab).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tablist")).toHaveAttribute("aria-orientation", narrow ? "horizontal" : "vertical");
  });
});
