/**
 * PostDetailPage 测试 —— 编辑帖子可见范围（Bug #9 回归）。
 *
 * 断言：
 * - 编辑面板用 VisibilitySelector（checkbox 三选 + 群搜索 + 群多选），不再是无群选择的 select；
 * - 保存时 updatePost 携带 allowed_group_ids；
 * - group 可见但未选任何群时阻止保存并提示"请至少选择一个群"；
 * - 群内帖子（post.group 有值）编辑时默认指定群可见，且自动勾选所属群。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as postsApi from "../api/posts";
import type { Post } from "../api/types";
import { PostDetailPage } from "../pages/PostDetailPage";
import { useChatStore } from "../stores/chat";
import { usePostsStore } from "../stores/posts";
import { surfaceEntryVariants, panelVariants } from "../components/motion/auroraquaMotion";

vi.mock("../components/motion/auroraquaMotion", async () => {
  const actual = await vi.importActual<typeof import("../components/motion/auroraquaMotion")>("../components/motion/auroraquaMotion");
  return { ...actual, surfaceEntryVariants: vi.fn(actual.surfaceEntryVariants), panelVariants: vi.fn(actual.panelVariants) };
});

vi.mock("../api/posts", () => ({
  getPost: vi.fn(),
  listComments: vi.fn(),
  listCommentsPage: vi.fn().mockResolvedValue({ results: [], next_cursor: null, has_more: false, total: 0 }),
  updatePost: vi.fn(),
  deletePost: vi.fn(),
  reportPostViews: vi.fn().mockResolvedValue({ updated: {} }),
}));
vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn().mockResolvedValue([]),
  getFavoriteStatuses: vi.fn().mockImplementation(async (target_type, ids: string[]) => ({ target_type, statuses: Object.fromEntries(ids.map((id) => [id, null])) })),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));
vi.mock("../hooks/useSocialPage", () => ({
  useSocialPage: () => ({
    items: [groupConversation], loading: false, loadingMore: false, error: null,
    hasMore: false, total: 1, loadMore: vi.fn(), refresh: vi.fn(),
  }),
}));
vi.mock("../components/posts/CommentList", () => ({
  CommentList: ({ revealItems }: { revealItems?: boolean }) => <div data-comment-reveal={String(revealItems)}>评论列表 mock</div>,
}));

const author = {
  id: "u1",
  username: "alice",
  nickname: "爱丽丝",
  avatar: "",
  signature: "",
  status: "online" as const,
  online: true,
  date_joined: "2026-01-01",
};

const makePost = (overrides: Partial<Post> = {}): Post => ({
  id: 1,
  author,
  author_id: "u1",
  title: "标题",
  body: "正文",
  visibility: "public",
  group: null,
  group_name: null,
  allowed_group_ids: undefined,
  images: [],
  comment_count: 0,
  is_author: true,
  view_count: 0,
  is_viewed: false,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
  ...overrides,
});

const existingImage: Post["images"][number] = {
  id: 1,
  media: {
    media_id: "m1",
    kind: "image",
    mime_type: "image/png",
    size: 100,
    status: "ready",
    width: null,
    height: null,
    duration: null,
    thumbnail: "/api/v1/media/m1/thumbnail",
    waveform: null,
    created_at: "2026-01-01T00:00:00Z",
  },
  order: 0,
};

const groupConversation = {
  id: "g1",
  type: "group" as const,
  title: "测试群",
  announcement: "",
  avatar: "",
  join_policy: "public" as const,
  owner_id: "u1",
  members: [],
  my_role: "owner" as const,
  member_count: 1,
  unread_count: 0,
  created_at: "2026-01-01T00:00:00Z",
  peer: null,
};

function renderDetail(post: Post, groupId?: string) {
  vi.mocked(postsApi.getPost).mockResolvedValue(post);
  vi.mocked(postsApi.listComments).mockResolvedValue([]);
  vi.mocked(postsApi.updatePost).mockResolvedValue(post);
  return render(
    <MemoryRouter initialEntries={["/posts/1"]}>
      <Routes>
        <Route path="/posts/:postId" element={<PostDetailPage groupId={groupId} />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  usePostsStore.setState({ posts: [] });
  useChatStore.getState().reset();
  useChatStore.getState().setConversations([groupConversation]);
  vi.clearAllMocks();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("PostDetailPage 分区入场边界", () => {
  it.each([false, true])("群外正文保留原500ms缩放位移和内部reveal，顶栏与输入框独立（narrow=%s）", async (narrow) => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === "(max-width: 768px)" && narrow, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    const post = makePost();
    usePostsStore.setState({ posts: [post] });
    const { container } = renderDetail(post);
    const body = container.querySelector<HTMLElement>(".post-detail-scroll")!;
    expect(body.style.transform).toContain("translateY(20px)");
    expect(body.style.transform).toContain("scale(0.95)");
    expect(vi.mocked(surfaceEntryVariants).mock.results.at(-1)?.value.in).toMatchObject({ transition: { duration: 0.5, ease: [0, 0, 0.58, 1] } });
    expect(body.querySelector(".post-detail-card")).toHaveClass("reveal");
    expect(body.querySelector(".post-detail-comments")).toHaveClass("reveal");
    expect(await screen.findByText("评论列表 mock")).toHaveAttribute("data-comment-reveal", "true");
    const head = container.querySelector(".post-detail-head")!;
    const composer = container.querySelector(".post-detail-composer")!;
    expect(head.parentElement).toBe(body.parentElement);
    expect(composer.parentElement).toBe(body.parentElement);
    expect(composer).toHaveStyle({ transform: "translateY(0)" });
    await waitFor(() => expect(body.style.transform).toBe("none"));
    expect(container.querySelector(".post-detail-scroll")).toBe(body);
  });

  it.each([false, true])("群内正文补300ms入场，仍不启用群外评论stagger或重挂正文（narrow=%s）", async (narrow) => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === "(max-width: 768px)" && narrow, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    const post = makePost({ group: "g1" });
    usePostsStore.setState({ posts: [post] });
    const { container } = renderDetail(post, "g1");
    const body = container.querySelector<HTMLElement>(".post-detail-scroll")!;
    expect(body.style.transform).toContain("translateX(20px)");
    expect(body.style.transform).not.toContain("scale");
    expect(vi.mocked(panelVariants).mock.results.at(-1)?.value.center).toMatchObject({ transition: { duration: 0.3 } });
    expect(body.querySelector(".post-detail-card")).not.toHaveClass("reveal");
    expect(screen.getByText("评论列表 mock")).toHaveAttribute("data-comment-reveal", "false");
    await waitFor(() => expect(body.style.transform).toBe("none"));
    expect(container.querySelector(".post-detail-scroll")).toBe(body);
  });

  it("群外 reduced-motion 正文首帧即完整显示，不先闪透明帧", async () => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query.includes("prefers-reduced-motion"), addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    const post = makePost();
    usePostsStore.setState({ posts: [post] });
    const { container } = renderDetail(post);
    const body = container.querySelector<HTMLElement>(".post-detail-scroll")!;
    expect(body.style.opacity).toBe("1");
    expect(body.style.transform).toBe("none");
    await waitFor(() => expect(postsApi.getPost).toHaveBeenCalledWith(1));
  });
});

describe("PostDetailPage 编辑可见范围", () => {
  it("保存期间冻结标题正文与可见范围，拒绝重复请求，失败恢复原草稿", async () => {
    let reject!: (error: Error) => void;
    renderDetail(makePost());
    vi.mocked(postsApi.updatePost).mockReturnValueOnce(new Promise((_yes, no) => { reject = no; }));
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));
    fireEvent.change(screen.getByRole("textbox", { name: "帖子正文" }), { target: { value: "待保存正文" } });
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));
    expect(screen.getByRole("textbox", { name: "帖子标题" })).toBeDisabled();
    expect(screen.getByRole("textbox", { name: "帖子正文" })).toBeDisabled();
    expect(screen.getByRole("checkbox", { name: "公开" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "取消编辑" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "保存中…" }));
    expect(postsApi.updatePost).toHaveBeenCalledTimes(1);
    await act(async () => reject(new Error("编辑保存失败")));
    expect(screen.getByRole("textbox", { name: "帖子正文" })).toBeEnabled();
    expect(screen.getByRole("textbox", { name: "帖子正文" })).toHaveValue("待保存正文");
    expect(screen.getByRole("alert")).toHaveTextContent("编辑保存失败");
  });
  it("删除请求期间禁用重复提交，失败静默恢复可重试状态", async () => {
    // bcb00dc 起删除失败静默：无错误提示；核心意图保留——请求期间禁重复提交、
    // 失败后按钮恢复可重试。
    let reject!: (error: Error) => void;
    vi.mocked(postsApi.deletePost).mockReturnValueOnce(new Promise((_resolve, no) => { reject = no; }));
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "删除" }));
    fireEvent.click(screen.getByRole("button", { name: "确认删除？" }));
    const busy = screen.getByRole("button", { name: "删除中…" });
    expect(busy).toBeDisabled();
    fireEvent.click(busy);
    expect(postsApi.deletePost).toHaveBeenCalledTimes(1);
    await act(async () => reject(new Error("删除暂时失败")));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "删除" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "编辑" })).toBeInTheDocument();
  });
  it("编辑面板使用 VisibilitySelector，选择指定群后保存携带 allowed_group_ids", async () => {
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    // VisibilitySelector 渲染：checkbox 三选（不再是无群选择的普通 select）
    expect(screen.getByRole("checkbox", { name: "公开" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "好友可见" })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: "指定群可见" })).not.toBeChecked();
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();

    // 切到"指定群可见" → 出现群搜索与群多选
    fireEvent.click(screen.getByRole("checkbox", { name: "指定群可见" }));
    expect(screen.getByLabelText("搜索群")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: "测试群" }));

    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));
    await waitFor(() => {
      expect(postsApi.updatePost).toHaveBeenCalledWith(
        1,
        // public 与「指定群可见」是独立维度、可共存，后端映射 public 优先（design.md §12.8.1）；
        // 公开帖点「指定群可见」后公开仍勾选 → visibility 保持 public，群白名单作为附加维度随行
        expect.objectContaining({ visibility: "public", allowed_group_ids: ["g1"] }),
      );
    });
  });

  it("指定群可见但未选任何群时阻止保存并提示", async () => {
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    fireEvent.click(screen.getByRole("checkbox", { name: "指定群可见" }));
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));

    expect(await screen.findByText("请至少选择一个群")).toBeInTheDocument();
    expect(postsApi.updatePost).not.toHaveBeenCalled();
  });

  it("群内帖子编辑时默认指定群可见，所属群自动勾选并随保存携带", async () => {
    renderDetail(
      makePost({ group: "g1", group_name: "测试群", visibility: "group", allowed_group_ids: ["g1"] }),
    );
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    // 初始即勾选「指定群可见」并自动勾选所属群
    expect(screen.getByRole("checkbox", { name: "指定群可见" })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: "测试群" })).toBeChecked();

    // 直接重新发布：保持群可见 + 白名单
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));
    await waitFor(() => {
      expect(postsApi.updatePost).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ visibility: "group", allowed_group_ids: ["g1"] }),
      );
    });
  });

  it("从我的帖子进入详情时，返回保留在我的帖子列表", async () => {
    const detail = makePost();
    vi.mocked(postsApi.getPost).mockResolvedValue(detail);
    vi.mocked(postsApi.listComments).mockResolvedValue([]);
    render(
      <MemoryRouter initialEntries={["/posts/mine", "/posts/1?from=mine"]}>
        <Routes>
          <Route path="/posts/:postId" element={<PostDetailPage />} />
          <Route path="/posts/mine" element={<div>我的帖子页占位</div>} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText("评论列表 mock")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "返回" }));
    expect(await screen.findByText("我的帖子页占位")).toBeInTheDocument();
  });
});

describe("PostDetailPage 编辑媒体", () => {
  it("编辑只隔离原详情和评论输入，保留 DOM 草稿并在取消后恢复焦点和交互", async () => {
    const view = renderDetail(makePost());
    const edit = await screen.findByRole("button", { name: "编辑" });
    await screen.findByText("评论列表 mock");
    const detail = view.container.querySelector(".post-detail-scroll")!;
    const composer = view.container.querySelector(".post-detail-composer")!;
    const draft = composer.querySelector("textarea")!;
    fireEvent.change(draft, { target: { value: "编辑前的评论草稿" } });
    detail.scrollTop = 123;
    fireEvent.click(edit);
    const dialog = screen.getByRole("dialog", { name: "编辑帖子" });
    expect(dialog).not.toHaveAttribute("inert");
    expect(dialog).not.toHaveAttribute("aria-hidden");
    expect(screen.getByRole("textbox", { name: "帖子标题" })).toHaveFocus();
    const backgrounds = view.container.querySelectorAll(".post-detail.is-editing > .post-detail-background");
    expect(backgrounds).toHaveLength(3);
    backgrounds.forEach((node) => {
      expect(node).toHaveAttribute("inert", "");
      expect(node).toHaveAttribute("aria-hidden", "true");
    });
    expect(view.container.querySelector(".post-detail-scroll")).toBe(detail);
    expect(detail.scrollTop).toBe(123);
    fireEvent.click(screen.getByRole("button", { name: "取消编辑" }));
    expect(view.container.querySelector(".post-detail-composer")).toBe(composer);
    expect(draft).toHaveValue("编辑前的评论草稿");
    expect(detail).not.toHaveAttribute("inert");
    expect(composer).not.toHaveAttribute("aria-hidden");
    await waitFor(() => expect(edit).toHaveFocus());
  });

  it("编辑面板提供媒体上传入口", async () => {
    renderDetail(makePost());
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    expect(screen.getByText("图片/视频 0/9")).toBeInTheDocument();
    expect(screen.getByLabelText("添加图片或视频")).toBeInTheDocument();
  });

  it("编辑带图帖子且不改动图片时，不携带 images 字段", async () => {
    renderDetail(makePost({ images: [existingImage] }));
    fireEvent.click(await screen.findByRole("button", { name: "编辑" }));

    expect(screen.getByLabelText("已添加 1 个媒体")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "重新发布" }));

    await waitFor(() => {
      expect(postsApi.updatePost).toHaveBeenCalledWith(
        1,
        expect.not.objectContaining({ images: expect.anything() }),
      );
    });
  });
});
