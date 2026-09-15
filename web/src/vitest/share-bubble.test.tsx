/**
 * ShareBubble / shareRoutes 渲染与跳转测试。
 * - 六类分享卡渲染（标签/标题/副标题）
 * - 封面（ResourceImage mock）与无封面回退
 * - 点击跳转：群聊分流（群内有条目→群内路径；无→群外路径）与群外路径
 * - shareRoutes 纯函数边界（未知类型/缺 payload/groupId 静态分支）
 */
import { render, screen, waitFor } from "@testing-library/react";
import { fireEvent } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage } from "../api/types";
import { ShareBubble, ShareTypeIcon } from "../components/chat/ShareBubble";
import { sharePreviewText, shareTargetRoute } from "../utils/shareRoutes";

vi.mock("../components/ResourceImage", () => ({
  ResourceImage: (props: { src: string; alt: string; className?: string }) => (
    <img src={props.src} alt={props.alt} className={props.className} data-testid="resource-image" />
  ),
}));

vi.mock("../api/voice", () => ({ listVoiceChannels: vi.fn() }));
vi.mock("../api/live", () => ({ listLiveChannels: vi.fn() }));
vi.mock("../api/posts", () => ({ listPosts: vi.fn() }));
vi.mock("../api/boardgame", () => ({ listGameRooms: vi.fn() }));

import * as boardgameApi from "../api/boardgame";
import * as liveApi from "../api/live";
import * as postsApi from "../api/posts";
import * as voiceApi from "../api/voice";
import { useChatStore } from "../stores/chat";

function makeMessage(over: Partial<ChatMessage>): ChatMessage {
  return {
    id: "m1",
    conversation_id: "c1",
    sender_id: "u1",
    type: "share",
    content: "",
    media_id: null,
    status: "sent",
    seq: 1,
    created_at: "2026-09-15T00:00:00Z",
    ...over,
  } as ChatMessage;
}

let lastLocation = "";

function LocationProbe() {
  const loc = useLocation();
  lastLocation = loc.pathname;
  return null;
}

function renderBubble(message: ChatMessage, groupId?: string | null) {
  return render(
    <MemoryRouter initialEntries={["/chat/c1"]}>
      <LocationProbe />
      <Routes>
        <Route path="/chat/c1" element={<ShareBubble message={message} groupId={groupId} />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
  lastLocation = "";
});

describe("ShareBubble 渲染", () => {
  it("六类分享源渲染标题/标签/副标题", () => {
    const cases: Array<[{ share_type: string; target_id: string; title: string; subtitle?: string }, string]> = [
      [{ share_type: "group", target_id: "g1", title: "测试群", subtitle: "3 人" }, "群聊"],
      [{ share_type: "voice", target_id: "v1", title: "连麦房", subtitle: "2 人" }, "语音房"],
      [{ share_type: "live", target_id: "l1", title: "爱莉直播", subtitle: "主播" }, "直播间"],
      [{ share_type: "post", target_id: "p1", title: "新帖", subtitle: "作者" }, "帖子"],
      [{ share_type: "boardgame", target_id: "b1", title: "桌游房", subtitle: "狼人杀" }, "桌游室"],
      [{ share_type: "user", target_id: "u9", title: "小汐", subtitle: "在线" }, "用户"],
    ];
    for (const [payload, label] of cases) {
      const { unmount } = renderBubble(makeMessage({ share_payload: payload as never }));
      expect(screen.getByText(payload.title)).toBeTruthy();
      expect(screen.getAllByText(new RegExp(label)).length).toBeGreaterThan(0);
      unmount();
    }
  });

  it("有封面时经 ResourceImage 渲染；无封面时渐变占位", () => {
    const { unmount } = renderBubble(
      makeMessage({
        share_payload: { share_type: "live", target_id: "l2", title: "有封面", cover: "/api/v1/media/m9/content" },
      }),
    );
    const img = screen.getByTestId("resource-image");
    expect(img.getAttribute("src")).toBe("/api/v1/media/m9/content");
    unmount();

    const { unmount: u2 } = renderBubble(
      makeMessage({ share_payload: { share_type: "post", target_id: "p2", title: "无封面" } }),
    );
    expect(screen.queryByTestId("resource-image")).toBeNull();
    expect(document.querySelector(".share-bubble-cover-fallback")).toBeTruthy();
    u2();
  });

  it("类型图标映射正确（ShareTypeIcon）", () => {
    const { container } = render(
      <MemoryRouter initialEntries={["/"]}>
        <ShareTypeIcon shareType="voice" />
      </MemoryRouter>,
    );
    expect(container.querySelector("svg")).toBeTruthy();
  });

  it("缺 payload 时展示 content 兜底文案且不可跳转（disabled）", () => {
    renderBubble(makeMessage({ content: "旧版分享" }));
    const btn = document.querySelector(".share-bubble-card") as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
    expect(screen.getByText("旧版分享")).toBeTruthy();
  });
});

describe("ShareBubble 跳转（群聊分流）", () => {
  it("群分享：已加入 → /group/:id；未加入 → GROUP REQUEST 弹窗（不跳转）", async () => {
    // 已加入：store 会话列表含该群 → 正常跳转
    useChatStore.setState({ conversations: [{ id: "g42", type: "group", title: "我的群" }] as never });
    renderBubble(
      makeMessage({ share_payload: { share_type: "group", target_id: "g42", title: "我的群" } }),
      "g42",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/group/g42"));
    expect(voiceApi.listVoiceChannels).not.toHaveBeenCalled();
    useChatStore.setState({ conversations: [] as never });

    // 未加入：弹 GROUP REQUEST 申请弹窗，不跳转
    renderBubble(
      makeMessage({ share_payload: { share_type: "group", target_id: "g99", title: "别人的群" } }),
      "g99",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(document.querySelector(".group-apply-overlay")).toBeTruthy());
    expect(document.querySelector(".group-apply-kicker")?.textContent).toContain("GROUP REQUEST");
    expect(lastLocation).not.toBe("/group/g99");
  });

  it("语音房：群目录命中 → 群内路径；未命中 → 群外路径", async () => {
    (voiceApi.listVoiceChannels as ReturnType<typeof vi.fn>).mockResolvedValue([
      { id: "vc7" },
      { id: "vc9" },
    ]);
    renderBubble(
      makeMessage({ share_payload: { share_type: "voice", target_id: "vc7", title: "房" } }),
      "g9",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/group/g9/voice/vc7"));
    lastLocation = "";

    renderBubble(
      makeMessage({ share_payload: { share_type: "voice", target_id: "vc8", title: "房" } }),
      "g9",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/voice/vc8"));
  });

  it("直播：群目录命中 → 群内；未命中 → 群外", async () => {
    (liveApi.listLiveChannels as ReturnType<typeof vi.fn>).mockResolvedValue([{ id: "lc1" }]);
    renderBubble(
      makeMessage({ share_payload: { share_type: "live", target_id: "lc1", title: "x" } }),
      "g5",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/group/g5/live/lc1"));
    lastLocation = "";

    (liveApi.listLiveChannels as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    renderBubble(
      makeMessage({ share_payload: { share_type: "live", target_id: "lc2", title: "x" } }),
      "g5",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/live/lc2"));
  });

  it("帖子：群目录命中 → 群内详情；未命中 → 群外", async () => {
    (postsApi.listPosts as ReturnType<typeof vi.fn>).mockResolvedValue({ results: [{ id: 5 }] });
    renderBubble(
      makeMessage({ share_payload: { share_type: "post", target_id: "5", title: "x" } }),
      "g5",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/group/g5/posts/5"));
  });

  it("桌游：群目录命中 → /group/:gid/games；未命中 → /games/:id", async () => {
    (boardgameApi.listGameRooms as ReturnType<typeof vi.fn>).mockResolvedValue([{ id: 9 }]);
    renderBubble(
      makeMessage({ share_payload: { share_type: "boardgame", target_id: "9", title: "x" } }),
      "g5",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/group/g5/games"));

    (boardgameApi.listGameRooms as ReturnType<typeof vi.fn>).mockResolvedValue([]);
    renderBubble(
      makeMessage({ share_payload: { share_type: "boardgame", target_id: "10", title: "x" } }),
      "g5",
    );
    fireEvent.click(screen.getByRole("button"));
    await waitFor(() => expect(lastLocation).toBe("/games/10"));
  });

  it("群外场景（私聊）：voice/live/post/boardgame/user 全部走群外路径", async () => {
    const cases: Array<[{ share_type: string; target_id: string; title: string }, string]> = [
      [{ share_type: "voice", target_id: "vc1", title: "x" }, "/voice/vc1"],
      [{ share_type: "live", target_id: "lc1", title: "x" }, "/live/lc1"],
      [{ share_type: "post", target_id: "p5", title: "x" }, "/posts/p5"],
      [{ share_type: "boardgame", target_id: "bg1", title: "x" }, "/games/bg1"],
      [{ share_type: "user", target_id: "u3", title: "x" }, "/user/u3"],
    ];
    for (const [payload, expected] of cases) {
      renderBubble(makeMessage({ share_payload: payload as never }));
      fireEvent.click(screen.getByRole("button"));
      await waitFor(() => expect(lastLocation).toBe(expected));
      lastLocation = "";
    }
  });
});

describe("shareRoutes 纯函数", () => {
  it("六类静态路由映射齐全且未知类型/缺 id 返回 null", () => {
    expect(shareTargetRoute({ share_type: "group", target_id: "g1", title: "t" })).toBe("/group/g1");
    expect(shareTargetRoute({ share_type: "voice", target_id: "v1", title: "t" })).toBe("/voice/v1");
    expect(shareTargetRoute({ share_type: "live", target_id: "l1", title: "t" })).toBe("/live/l1");
    expect(shareTargetRoute({ share_type: "post", target_id: "p1", title: "t" })).toBe("/posts/p1");
    expect(shareTargetRoute({ share_type: "boardgame", target_id: "b1", title: "t" })).toBe("/games/b1");
    expect(shareTargetRoute({ share_type: "user", target_id: "u1", title: "t" })).toBe("/user/u1");
    expect(shareTargetRoute({ share_type: "hacker" as never, target_id: "x", title: "t" })).toBeNull();
    expect(shareTargetRoute(null)).toBeNull();
    expect(shareTargetRoute({ share_type: "group", target_id: "", title: "t" })).toBeNull();
  });

  it("群聊上下文静态分支：groupId 非空 → 群内路径（boardgame 为群内场景页）", () => {
    expect(shareTargetRoute({ share_type: "voice", target_id: "v1", title: "t" }, "g9")).toBe("/group/g9/voice/v1");
    expect(shareTargetRoute({ share_type: "live", target_id: "l1", title: "t" }, "g9")).toBe("/group/g9/live/l1");
    expect(shareTargetRoute({ share_type: "post", target_id: "p1", title: "t" }, "g9")).toBe("/group/g9/posts/p1");
    expect(shareTargetRoute({ share_type: "boardgame", target_id: "b1", title: "t" }, "g9")).toBe("/group/g9/games");
    expect(shareTargetRoute({ share_type: "group", target_id: "g2", title: "t" }, "g9")).toBe("/group/g2");
  });

  it("预览兜底文案：[分享]标题，缺标题回退 content", () => {
    expect(sharePreviewText({ share_type: "group", target_id: "g1", title: "我的群" })).toBe("[分享]我的群");
    expect(sharePreviewText(null, "")).toBe("[分享]");
    expect(sharePreviewText({ share_type: "user", target_id: "u1", title: "  " }, "小汐")).toBe("[分享]小汐");
  });
});
