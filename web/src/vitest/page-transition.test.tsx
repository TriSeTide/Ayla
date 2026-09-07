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

  it("仅宽屏跨群共享外壳key，窄屏仍按群重挂进群编排", () => {
    expect(resolvePageKey("/group/g1", true)).toBe("wide-group-shell");
    expect(resolvePageKey("/group/g2/posts/p9", true)).toBe("wide-group-shell");
    expect(resolvePageKey("/group/g2/live/3", true)).toBe("wide-group-shell");
    expect(resolvePageKey("/group/g1", false)).not.toBe(resolvePageKey("/group/g2", false));
    expect(resolvePageKey("/group", true)).toBe("/group");
    expect(resolvePageKey("/voice", true)).toBe("/voice");
  });

  it("非群页路由用原始 pathname", () => {
    expect(resolvePageKey("/group")).toBe("/group");
    expect(resolvePageKey("/voice")).toBe("/voice");
    expect(resolvePageKey("/posts/p1")).toBe("/posts/p1");
    expect(resolvePageKey("/messages")).toBe("/messages");
    expect(resolvePageKey("/chat/c1")).toBe("/chat/c1");
  });

  it("宽屏私聊换对象保留会话列表外壳，窄屏仍有独立页面身份", () => {
    expect(resolvePageKey("/chat/a", true)).toBe("wide-private-chat-shell");
    expect(resolvePageKey("/chat/b", true)).toBe("wide-private-chat-shell");
    expect(resolvePageKey("/chat/a", false)).not.toBe(resolvePageKey("/chat/b", false));
    expect(resolvePageKey("/messages", true)).toBe("/messages");
  });

  it("直播间详情归一为 /live/room（上下滑切换不触发整页转场）", () => {
    expect(resolvePageKey("/live/42")).toBe("/live/room");
    expect(resolvePageKey("/live/100")).toBe("/live/room");
    // 列表页与详情页区分：进入/退出直播间仍走整页转场
    expect(resolvePageKey("/live")).toBe("/live");
    // 开播控制台归一为 /live/start：侧栏切频道不触发整页重挂载，避免新旧页
    // 并存竞争 liveSessionRuntime 单例（旧页 cleanup 的 leave 清掉新页会话，
    // channel 永不设置 → 控制台退化 + 弹幕断开，2026-09-06 事故）
    expect(resolvePageKey("/live/start/5")).toBe("/live/start");
    expect(resolvePageKey("/live/start/42")).toBe("/live/start");
    expect(resolvePageKey("/live/start")).toBe("/live/start");
  });
});

describe("PageTransition", () => {
  it.each(["/live/42", "/live/start/42"])("直播与开播页 %s 分面板编排时外层立即归位，不叠加缩放或位移", (pathname) => {
    const { container } = render(<PageTransition pathname={pathname} panelOwned>固定播放器</PageTransition>);
    const page = container.querySelector<HTMLElement>(".page-transition")!;
    expect(page.style.opacity).toBe("1");
    expect(page.style.transform).toBe("none");
  });
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
