/**
 * PageTransition 测试（方案 §2.1）：
 * - resolvePageKey：群页所有变体归一为 `/group/:id`，群内场景切换不触发整页转场
 *   （避免 GroupPage 重挂载 + 进群编排重跑）；非群页用原始 pathname。
 * - PageTransition：渲染 children（reduced-motion 精确 transform 由 Playwright 真实验收）。
 */
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PageTransition, resolvePageKey } from "../components/motion/PageTransition";

describe("resolvePageKey", () => {
  it("群页所有变体归一为 /group/:id（群内场景切换不触发整页转场）", () => {
    expect(resolvePageKey("/group/g1")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/posts")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/voice")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/games")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/info")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/posts/p9")).toBe("/group/g1");
    expect(resolvePageKey("/group/g1/voice/v3")).toBe("/group/g1");
  });

  it("非群页路由用原始 pathname", () => {
    expect(resolvePageKey("/group")).toBe("/group");
    expect(resolvePageKey("/voice")).toBe("/voice");
    expect(resolvePageKey("/posts/p1")).toBe("/posts/p1");
    expect(resolvePageKey("/messages")).toBe("/messages");
    expect(resolvePageKey("/chat/c1")).toBe("/chat/c1");
  });

  it("直播间详情归一为 /live/room（上下滑切换不触发整页转场）", () => {
    expect(resolvePageKey("/live/42")).toBe("/live/room");
    expect(resolvePageKey("/live/100")).toBe("/live/room");
    // 列表页与详情页区分：进入/退出直播间仍走整页转场
    expect(resolvePageKey("/live")).toBe("/live");
    // 开播控制台详情不归一（三段路径不匹配 /live/:id）
    expect(resolvePageKey("/live/start/5")).toBe("/live/start/5");
  });
});

describe("PageTransition", () => {
  it("渲染 children（普通路由）", () => {
    render(<PageTransition pathname="/voice">语音内容</PageTransition>);
    expect(screen.getByText("语音内容")).toBeInTheDocument();
  });

  it("渲染 children（群页走无位移淡入分支）", () => {
    render(<PageTransition pathname="/group/g1">群聊内容</PageTransition>);
    expect(screen.getByText("群聊内容")).toBeInTheDocument();
  });

  it("普通路由 initial 应用 y 位移（transform 含 translateY(20px) + opacity 0）", () => {
    const { container } = render(<PageTransition pathname="/voice">语音内容</PageTransition>);
    const el = container.querySelector(".page-transition") as HTMLElement;
    expect(el.style.opacity).toBe("0");
    expect(el.style.transform).toContain("translateY(20px)");
  });

  it("搜索路由 initial 应用负向位移（translateY(-20px)，从上往下展开）", () => {
    const { container } = render(<PageTransition pathname="/search">搜索内容</PageTransition>);
    const el = container.querySelector(".page-transition") as HTMLElement;
    expect(el.style.transform).toContain("translateY(-20px)");
  });

  it("群页 initial 无位移（仅 opacity 0，transform 不含 translateY）", () => {
    const { container } = render(<PageTransition pathname="/group/g1">群聊内容</PageTransition>);
    const el = container.querySelector(".page-transition") as HTMLElement;
    expect(el.style.opacity).toBe("0");
    expect(el.style.transform).not.toContain("translateY");
  });
});
