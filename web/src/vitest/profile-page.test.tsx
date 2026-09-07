/**
 * ProfilePage 头像上传测试（M5-2.1）：
 * - 选择合法图片 → 本地预览提示；非法类型 → 校验错误，不进入预览；
 * - 保存时三步上传 + PATCH avatar=content URL，成功后清除预览并更新 store；
 * - 上传失败保留文件，可再次保存重试。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import * as authApi from "../api/auth";
import type { UserPublic } from "../api/types";
import { ProfilePage } from "../pages/ProfilePage";
import { useAuthStore } from "../stores/auth";
import * as mediaApi from "../api/media";

vi.mock("../api/auth", () => ({ updateProfile: vi.fn() }));
vi.mock("../api/boardgame", () => ({ listGameRoomsPage: vi.fn().mockResolvedValue({ results: [], total: 0, has_more: false, next_cursor: null }) }));
vi.mock("../api/live", () => ({ listLiveChannelsPage: vi.fn().mockResolvedValue({ results: [], total: 0, has_more: false, next_cursor: null }) }));
vi.mock("../api/posts", () => ({ listPosts: vi.fn().mockResolvedValue({ results: [], total: 0, has_more: false, next_cursor: null }) }));
vi.mock("../hooks/useAuth", () => ({ useAuth: () => ({ logout: vi.fn() }) }));
vi.mock("../api/media", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/media")>();
  return {
    ...actual,
    uploadMediaFile: vi.fn(),
    mediaContentUrl: (id: string) => `/api/v1/media/${id}/content`,
  };
});

function user(overrides: Partial<UserPublic> = {}): UserPublic {
  return {
    id: "u1",
    username: "alice",
    nickname: "爱丽丝",
    avatar: "",
    signature: "",
    status: "online",
    online: true,
    date_joined: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

function pngFile() {
  return new File(["img"], "a.png", { type: "image/png" });
}

function renderPage() {
  return render(
    <MemoryRouter>
      <ProfilePage />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  // jsdom 未实现 objectURL：仅覆盖两个静态方法，保留 URL 构造器
  Object.defineProperty(URL, "createObjectURL", {
    value: vi.fn(() => "blob:mock-avatar"),
    configurable: true,
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    value: vi.fn(),
    configurable: true,
  });
  vi.mocked(mediaApi.uploadMediaFile).mockReset();
  vi.mocked(authApi.updateProfile).mockReset();
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: user(),
  });
});

describe("ProfilePage 头像上传", () => {
  it("trim 保存成功回填本次提交内容并解除 dirty", async () => {
    vi.mocked(authApi.updateProfile).mockResolvedValue(user({ nickname: "新昵称", signature: "新签名" }));
    renderPage();
    fireEvent.change(screen.getByLabelText("昵称"), { target: { value: "  新昵称  " } });
    fireEvent.change(screen.getByLabelText("个性签名"), { target: { value: " 新签名 " } });
    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    await screen.findByText("已保存");
    expect(authApi.updateProfile).toHaveBeenCalledWith(expect.objectContaining({ nickname: "新昵称", signature: "新签名" }));
    expect(screen.getByLabelText("昵称")).toHaveValue("新昵称");
    expect(screen.getByLabelText("个性签名")).toHaveValue("新签名");
    expect(screen.getByRole("button", { name: "保存修改" })).toBeDisabled();
  });

  it("保存回包保留等待期间新编辑的草稿，只同步未再编辑的字段", async () => {
    let finish!: (value: UserPublic) => void;
    vi.mocked(authApi.updateProfile).mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    renderPage();
    fireEvent.change(screen.getByLabelText("昵称"), { target: { value: "  已提交 " } });
    fireEvent.change(screen.getByLabelText("个性签名"), { target: { value: " 已提交签名 " } });
    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    fireEvent.change(screen.getByLabelText("昵称"), { target: { value: "  下一版草稿  " } });
    await act(async () => { finish(user({ nickname: "已提交", signature: "已提交签名" })); });
    expect(screen.getByLabelText("昵称")).toHaveValue("  下一版草稿  ");
    expect(screen.getByLabelText("个性签名")).toHaveValue("已提交签名");
    expect(screen.getByRole("button", { name: "保存修改" })).toBeEnabled();
    expect(screen.queryByText("已保存")).not.toBeInTheDocument();
  });

  it("保存头像期间另选图片，旧回包不清除新头像草稿", async () => {
    let finish!: (value: UserPublic) => void;
    vi.mocked(mediaApi.uploadMediaFile).mockResolvedValue({ media_id: "old", descriptor: {} as never, upload_id: "old" });
    vi.mocked(authApi.updateProfile).mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    vi.mocked(URL.createObjectURL).mockReturnValueOnce("blob:old").mockReturnValueOnce("blob:new");
    renderPage();
    fireEvent.change(screen.getByLabelText("更换头像"), { target: { files: [pngFile()] } });
    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    await waitFor(() => expect(authApi.updateProfile).toHaveBeenCalledTimes(1));
    fireEvent.change(screen.getByLabelText("更换头像"), { target: { files: [new File(["new"], "new.png", { type: "image/png" })] } });
    await act(async () => { finish(user({ avatar: "/old-avatar" })); });
    expect(screen.getByText("新头像将在保存后生效")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "保存修改" })).toBeEnabled();
  });

  it("选择合法图片显示本地预览提示", async () => {
    renderPage();
    const input = screen.getByLabelText("更换头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");
  });

  it("非法类型被本地校验拦截，不进入预览", async () => {
    renderPage();
    const input = screen.getByLabelText("更换头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [new File(["x"], "a.txt", { type: "text/plain" })] } });
    await screen.findByText("仅支持图片文件（PNG/JPEG/GIF/WebP/AVIF/HEIC/BMP/TIFF/ICO/SVG）");
    expect(screen.queryByText("新头像将在保存后生效")).not.toBeInTheDocument();
  });

  it("保存时三步上传并用 content URL PATCH，成功后清除预览", async () => {
    vi.mocked(mediaApi.uploadMediaFile).mockResolvedValue({ media_id: "m-1", descriptor: {} as never, upload_id: "u-1" });
    vi.mocked(authApi.updateProfile).mockResolvedValue(user({ avatar: "/api/v1/media/m-1/content" }));
    renderPage();
    const input = screen.getByLabelText("更换头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");

    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    await waitFor(() => expect(authApi.updateProfile).toHaveBeenCalledTimes(1));
    expect(mediaApi.uploadMediaFile).toHaveBeenCalledWith(pngFile(), "image");
    expect(authApi.updateProfile).toHaveBeenCalledWith(expect.objectContaining({ avatar: "/api/v1/media/m-1/content" }));
    // 成功后预览提示消失
    await waitFor(() =>
      expect(screen.queryByText("新头像将在保存后生效")).not.toBeInTheDocument(),
    );
  });

  it("上传失败保留文件，可再次保存重试", async () => {
    vi.mocked(mediaApi.uploadMediaFile)
      .mockRejectedValueOnce(new Error("网络失败"))
      .mockResolvedValueOnce({ media_id: "m-2", descriptor: {} as never, upload_id: "u-2" });
    vi.mocked(authApi.updateProfile).mockResolvedValue(user({ avatar: "/api/v1/media/m-2/content" }));
    renderPage();
    const input = screen.getByLabelText("更换头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");

    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    await screen.findByRole("alert");
    // 失败后预览仍在（文件保留），可重试
    expect(screen.getByText("新头像将在保存后生效")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "保存修改" }));
    await waitFor(() => expect(authApi.updateProfile).toHaveBeenCalledTimes(1));
    expect(mediaApi.uploadMediaFile).toHaveBeenCalledTimes(2);
    await waitFor(() =>
      expect(screen.queryByText("新头像将在保存后生效")).not.toBeInTheDocument(),
    );
  });
});
