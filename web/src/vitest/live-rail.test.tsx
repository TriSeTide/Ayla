/**
 * 直播间频道封面侧栏 + 大厅封面测试（需求）：
 * - LiveChannelRail 宽屏展开态：返回键在侧栏内 + 封面列 + 点击切换 + 收起；
 * - LiveChannelRail 收起态：窄条（保留返回 + 展开）；
 * - LiveChannelRail 窄屏覆盖层：showBack=false 无返回键（返回键在左上角）；
 * - LiveHall 卡片：封面占位 + 状态徽章 + 来源标识 + 点击进入。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveChannelRail } from "../components/live/LiveChannelRail";
import { LiveHall } from "../components/live/LiveHall";
import { LiveStartSheet } from "../components/live/LiveStartSheet";
import * as liveApi from "../api/live";

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

describe("LiveChannelRail 收起态（返回 null，返回/展开键移到顶栏）", () => {
  it("收起后侧栏不渲染任何内容（返回/展开键由 LiveRoomBody 顶栏承载）", () => {
    const { container } = render(
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
    // 收起态返回 null：无侧栏、无浮动按钮、无封面列表
    expect(document.querySelector(".live-rail")).toBeNull();
    expect(document.querySelector(".live-rail-float")).toBeNull();
    expect(document.querySelector(".live-rail-collapsed")).toBeNull();
    expect(screen.queryByRole("button", { name: "切换到直播间 第一场直播" })).not.toBeInTheDocument();
    expect(container.innerHTML).toBe("");
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

describe("LiveStartSheet 开播选择器", () => {
  it("只展示自己的直播间，选择后进入开播控制台", async () => {
    const mine = { ...liveCh(1, "我的直播间"), is_owner: true };
    const other = { ...liveCh(2, "别人的直播间"), is_owner: false };
    const request = vi.spyOn(liveApi, "listLiveChannels").mockResolvedValue([mine, other]);
    const onStart = vi.fn();
    const onCreateNew = vi.fn();
    render(<LiveStartSheet onStart={onStart} onCreateNew={onCreateNew} />);
    await waitFor(() => expect(screen.getByRole("button", { name: /我的直播间/ })).toBeInTheDocument());
    screen.getByRole("button", { name: "+ 添加新的直播间" }).click();
    expect(onCreateNew).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: /别人的直播间/ })).not.toBeInTheDocument();
    screen.getByRole("button", { name: /我的直播间/ }).click();
    expect(onStart).toHaveBeenCalledWith(mine);
    request.mockRestore();
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

describe("LiveChannelRail 开播控制台扩展（删除 + 新建）", () => {
  it("提供 onDeleteChannel 时每项渲染删除按钮，点击调回调且不影响切换", () => {
    const onSelect = vi.fn();
    const onDelete = vi.fn();
    render(
      <LiveChannelRail
        channels={[liveCh(1, "第一场直播")]}
        currentId={1}
        onSelect={onSelect}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
        onDeleteChannel={onDelete}
      />,
    );
    const del = screen.getByRole("button", { name: "删除直播间 第一场直播" });
    del.click();
    expect(onDelete).toHaveBeenCalledWith(1);
    expect(onSelect).not.toHaveBeenCalled();
  });

  it("提供 onCreateNewChannel 时底部渲染加号键，点击调回调", () => {
    const onCreateNew = vi.fn();
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
        onCreateNewChannel={onCreateNew}
      />,
    );
    screen.getByRole("button", { name: "新建直播间" }).click();
    expect(onCreateNew).toHaveBeenCalledTimes(1);
  });

  it("未提供删除/新建回调时不渲染对应按钮（普通观看页侧栏）", () => {
    render(
      <LiveChannelRail
        channels={channels}
        currentId={1}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
      />,
    );
    expect(screen.queryByRole("button", { name: "新建直播间" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /删除直播间/ })).not.toBeInTheDocument();
  });
});
