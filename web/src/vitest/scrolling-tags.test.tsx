/**
 * ScrollingTags 契约测试：
 * - 标签组渲染 + 容器 className 透传；
 * - title 属性保留完整标签串（滚动时的可读兜底）；
 * - jsdom 无 ResizeObserver / 零宽场景不误判溢出（不挂 is-overflow、不设滚动变量）。
 */
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ScrollingTags } from "../components/ScrollingTags";

describe("ScrollingTags 标签组横向滚动", () => {
  it("渲染全部标签并透传容器 className 与标签 className", () => {
    const { container } = render(
      <ScrollingTags
        labels={["公开", "好友", "测试群"]}
        tagClassName="voice-source-tag"
        className="voice-source-tags"
      />,
    );
    expect(screen.getByText("公开")).toBeInTheDocument();
    expect(screen.getByText("好友")).toBeInTheDocument();
    expect(screen.getByText("测试群")).toBeInTheDocument();
    const el = container.querySelector(".scroll-tags");
    expect(el).toHaveClass("voice-source-tags");
    expect(container.querySelectorAll(".voice-source-tag")).toHaveLength(3);
  });

  it("title 属性保留完整标签串，供滚动/截断时悬停查看", () => {
    render(
      <ScrollingTags
        labels={["公开", "好友"]}
        tagClassName="live-badge live-badge-source"
        className="live-card-source-tags"
        title="公开、好友"
      />,
    );
    expect(screen.getByTitle("公开、好友")).toBeInTheDocument();
  });

  it("零宽（jsdom 无 ResizeObserver / scrollWidth=0）不误判溢出", () => {
    const { container } = render(
      <ScrollingTags labels={["公开"]} tagClassName="voice-source-tag" className="voice-source-tags" />,
    );
    const el = container.querySelector(".scroll-tags");
    expect(el).not.toHaveClass("is-overflow");
    expect(el?.querySelector(".scroll-tags-inner")?.getAttribute("style")).toBeNull();
  });
});
