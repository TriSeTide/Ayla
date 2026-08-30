/**
 * ScrollingText 契约测试：
 * - 文本渲染 + className 透传（容器承担布局角色）；
 * - 容器 title 属性保留完整文本（截断/滚动时的可读兜底）；
 * - jsdom 无 ResizeObserver / 零宽场景不误判溢出（不挂 is-overflow、不设滚动变量）。
 */
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ScrollingText } from "../components/ScrollingText";

describe("ScrollingText 长文本单行滚动", () => {
  it("渲染文本内容并透传 className", () => {
    const { container } = render(
      <ScrollingText text="很长的房间名" className="live-room-title" />,
    );
    expect(screen.getByText("很长的房间名")).toBeInTheDocument();
    const el = container.querySelector(".scroll-text");
    expect(el).toHaveClass("live-room-title");
  });

  it("容器 title 属性保留完整文本，供截断/滚动时悬停查看", () => {
    render(<ScrollingText text="完整标题" />);
    expect(screen.getByTitle("完整标题")).toBeInTheDocument();
  });

  it("零宽（jsdom 无 ResizeObserver / scrollWidth=0）不误判溢出", () => {
    const { container } = render(<ScrollingText text="短文本" />);
    const el = container.querySelector(".scroll-text");
    expect(el).not.toHaveClass("is-overflow");
    expect(el?.getAttribute("style")).toBeNull();
  });
});
