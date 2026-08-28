import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const motionState = vi.hoisted(() => ({
  onDragEnd: null as ((event: unknown, info: { offset: { x: number; y: number }; velocity: { x: number; y: number } }) => void) | null,
}));

vi.mock("framer-motion", () => {
  const MotionDiv = ({ children, onDragEnd }: { children?: unknown; onDragEnd?: typeof motionState.onDragEnd }) => {
    if (onDragEnd) motionState.onDragEnd = onDragEnd;
    return children;
  };
  return {
    AnimatePresence: ({ children }: { children?: unknown }) => children,
    motion: { div: MotionDiv },
  };
});

import { ImageViewer } from "../components/chat/ImageViewer";

const items = [
  { media: null, localUrl: "blob:one", alt: "第一张" },
  { media: null, localUrl: "blob:two", alt: "第二张" },
];

function renderViewer() {
  render(<ImageViewer items={items} onClose={vi.fn()} />);
  const stage = document.querySelector<HTMLElement>(".image-viewer-stage");
  if (!stage) throw new Error("查看器 stage 未渲染");
  Object.defineProperty(stage, "clientWidth", { configurable: true, value: 300 });
}

function dragEnd(
  type: string,
  offset: { x: number; y: number },
  velocity: { x: number; y: number },
) {
  if (!motionState.onDragEnd) throw new Error("查看器拖拽回调未注册");
  act(() => motionState.onDragEnd?.({ type }, { offset, velocity }));
}

describe("ImageViewer 横滑松手契约", () => {
  beforeEach(() => {
    motionState.onDragEnd = null;
  });

  it("pointercancel 只回弹，不在手指未松开时切图", () => {
    renderViewer();
    dragEnd("pointercancel", { x: -220, y: 0 }, { x: -900, y: 0 });
    expect(screen.getByRole("dialog", { name: "图片查看：1/2" })).toBeInTheDocument();
  });

  it("交叉轴位移占优时让位，不切换条目", () => {
    renderViewer();
    dragEnd("pointerup", { x: -140, y: 180 }, { x: -900, y: 0 });
    expect(screen.getByRole("dialog", { name: "图片查看：1/2" })).toBeInTheDocument();
  });

  it("同向甩动达到最小位移与速度阈值时切到下一条", () => {
    renderViewer();
    dragEnd("pointerup", { x: -60, y: 0 }, { x: -400, y: 0 });
    expect(screen.getByRole("dialog", { name: "图片查看：2/2" })).toBeInTheDocument();
  });
});
