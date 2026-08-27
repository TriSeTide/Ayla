import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationMember, UserPublic } from "../api/types";
import { MentionPicker } from "../components/chat/MentionPicker";
import { useAuthStore } from "../stores/auth";

function member(id: string, nickname: string, username: string): ConversationMember {
  return {
    id,
    user: {
      id,
      nickname,
      username,
      avatar: "",
      signature: "",
      status: "offline",
      online: false,
      date_joined: "",
    } as UserPublic,
    role: "member",
    muted: false,
    joined_at: "",
  };
}

const members = [
  member("u1", "张三", "zhangsan"),
  member("u2", "李四", "lisi"),
  member("u3", "王五", "wangwu"),
];

describe("MentionPicker 群成员选择器（M8）", () => {
  beforeEach(() => {
    useAuthStore.setState({ currentUser: { id: "u1", nickname: "张三", username: "zhangsan" } as UserPublic });
  });
  afterEach(() => {
    useAuthStore.setState({ currentUser: null });
  });

  it("空 query 显示全部成员（排除自己）", () => {
    render(<MentionPicker members={members} query="" onSelect={vi.fn()} />);
    expect(screen.getByRole("option", { name: "@李四" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "@王五" })).toBeInTheDocument();
    // 排除自己（u1）
    expect(screen.queryByRole("option", { name: "@张三" })).not.toBeInTheDocument();
  });

  it("query 按昵称过滤", () => {
    render(<MentionPicker members={members} query="李" onSelect={vi.fn()} />);
    expect(screen.getByRole("option", { name: "@李四" })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "@王五" })).not.toBeInTheDocument();
  });

  it("query 按用户名过滤（大小写不敏感）", () => {
    render(<MentionPicker members={members} query="WANG" onSelect={vi.fn()} />);
    expect(screen.getByRole("option", { name: "@王五" })).toBeInTheDocument();
  });

  it("无匹配显示空态", () => {
    render(<MentionPicker members={members} query="不存在" onSelect={vi.fn()} />);
    expect(screen.getByText("无匹配成员")).toBeInTheDocument();
  });

  it("点击选中回调对应成员", () => {
    const onSelect = vi.fn();
    render(<MentionPicker members={members} query="" onSelect={onSelect} />);
    fireEvent.click(screen.getByRole("option", { name: "@李四" }));
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ id: "u2" }));
  });
});
