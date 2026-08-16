/**
 * 直播间频道封面侧栏 + 大厅封面测试（需求）：
 * - LiveChannelRail 宽屏展开态：返回键在侧栏内 + 封面列 + 点击切换 + 收起；
 * - LiveChannelRail 收起态：窄条（保留返回 + 展开）；
 * - LiveChannelRail 窄屏覆盖层：showBack=false 无返回键（返回键在左上角）；
 * - LiveHall 卡片：封面占位 + 状态徽章 + 来源标识 + 点击进入。
 */
import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveChannelRail } from "../components/live/LiveChannelRail";
import { LiveHall } from "../components/live/LiveHall";

function liveCh(id: number, title: string, status: LiveChannelDescriptor["status"] = "live"): LiveChannelDescriptor {
  return {
    id,
    title,
    status,
    visibility: "public",
    group: null,
    group_name: null,
    owner_id: `u${id}`,
    owner_nickname: null,
    is_owner: false,
    stream_key: null,
    rtmp_url: null,
    hls_url: `hls://${id}`,
    flv_url: `flv://${id}`,
    started_at: null,
    ended_at: null,
    created_at: "2026-01-01T00:00:00Z",
  };
}

const channels = [liveCh(1, "第一场直播"), liveCh(2, "第二场直播"), liveCh(3, "第三场直播")];

describe("LiveChannelRail 宽屏展开态", () => {
  it("返回键在侧栏内 + 封面列渲染 + 当前项高亮", () => {
    const onBack = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={2}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={onBack}
        showBack
      />,
    );
    // 返回键在侧栏（宽屏需求）
    const backBtn = screen.getByRole("button", { name: "返回" });
    expect(backBtn).toBeInTheDocument();
    // 三个频道封面项
    expect(screen.getByRole("button", { name: "切换到直播间 第一场直播" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "切换到直播间 第二场直播" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "切换到直播间 第三场直播" })).toBeInTheDocument();
    // 当前项 aria-current
    const active = screen.getByRole("button", { name: "切换到直播间 第二场直播" });
    expect(active.getAttribute("aria-current")).toBe("true");
    // 点击返回
    backBtn.click();
    expect(onBack).toHaveBeenCalledTimes(1);
  });

  it("点击封面 → onSelect 切换直播间", () => {
    const onSelect = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={onSelect}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
      />,
    );
    screen.getByRole("button", { name: "切换到直播间 第三场直播" }).click();
    expect(onSelect).toHaveBeenCalledWith(3);
  });

  it("收起按钮 → onToggle（收起侧栏）", () => {
    const onToggle = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={onToggle}
        onBack={vi.fn()}
        showBack
      />,
    );
    screen.getByRole("button", { name: "收起直播间列表" }).click();
    expect(onToggle).toHaveBeenCalledTimes(1);
  });
});

describe("LiveChannelRail 收起态（浮动按钮，不留侧栏）", () => {
  it("收起后整体收成一个浮动按钮（返回 + 展开），无封面列表", () => {
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
      />,
    );
    // 浮动按钮组存在（不再是 .live-rail 侧栏 / .live-rail-collapsed 窄条）
    expect(document.querySelector(".live-rail-float")).not.toBeNull();
    expect(document.querySelector(".live-rail")).toBeNull();
    expect(document.querySelector(".live-rail-collapsed")).toBeNull();
    // 返回键 + 展开键正常显示
    expect(screen.getByRole("button", { name: "返回" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "展开直播间列表" })).toBeInTheDocument();
    // 封面列表项被收起隐藏
    expect(screen.queryByRole("button", { name: "切换到直播间 第一场直播" })).not.toBeInTheDocument();
  });

  it("收起态浮动按钮展开键 → onToggle", () => {
    const onToggle = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed
        onToggle={onToggle}
        onBack={vi.fn()}
        showBack
      />,
    );
    screen.getByRole("button", { name: "展开直播间列表" }).click();
    expect(onToggle).toHaveBeenCalledTimes(1);
  });
});

describe("LiveChannelRail 窄屏覆盖层", () => {
  it("showBack=false 侧栏内不渲染返回键（返回键在左上角，需求）", () => {
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack={false}
      />,
    );
    expect(screen.queryByRole("button", { name: "返回" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "切换到直播间 第二场直播" })).toBeInTheDocument();
  });

  it("点击封面 → onSelect 后由外层关闭覆盖层", () => {
    const onSelect = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={onSelect}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack={false}
      />,
    );
    screen.getByRole("button", { name: "切换到直播间 第三场直播" }).click();
    expect(onSelect).toHaveBeenCalledWith(3);
  });
});

describe("LiveHall 大厅卡片封面占位", () => {
  it("卡片渲染封面占位 + 状态徽章 + 来源标识 + 主播名", () => {
    const onEnter = vi.fn();
    render(
      <LiveHall
        channels={[liveCh(1, "爱莉电台", "live"), liveCh(2, "回放", "ended")]}
        elysiaUserId="u1"
        ownerNames={{ u1: "爱莉", u2: "小樱" }}
        onEnter={onEnter}
      />,
    );
    // 封面占位区（每卡片一个）
    expect(document.querySelectorAll(".live-card-cover").length).toBe(2);
    // 状态徽章
    expect(screen.getByText("直播中")).toBeInTheDocument();
    expect(screen.getByText("已结束")).toBeInTheDocument();
    // 来源标识（两个卡片都是公开）
    expect(screen.getAllByText("公开").length).toBe(2);
    // 爱莉角标（owner 是 elysiaUserId）+ 主播名都渲染
    expect(screen.getAllByText("爱莉").length).toBeGreaterThanOrEqual(2);
    expect(screen.getByText("小樱")).toBeInTheDocument();
    // 点击卡片进入
    screen.getByText("爱莉电台").click();
    expect(onEnter).toHaveBeenCalledWith(1);
  });

  it("owner_nickname 优先于 ownerNames 懒拉兜底（后端列表直接带主播名）", () => {
    const onEnter = vi.fn();
    const ch = { ...liveCh(1, "电台", "live"), owner_nickname: "主播小樱" };
    render(
      <LiveHall
        channels={[ch]}
        elysiaUserId={null}
        ownerNames={{ u1: "懒拉名字" }}
        onEnter={onEnter}
      />,
    );
    // 后端带的主播名优先；ownerNames 兜底不生效
    expect(screen.getByText("主播小樱")).toBeInTheDocument();
    expect(screen.queryByText("懒拉名字")).not.toBeInTheDocument();
  });
});
