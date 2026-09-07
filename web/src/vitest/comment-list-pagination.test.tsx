import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PostComment } from "../api/types";
import { CommentList } from "../components/posts/CommentList";

vi.mock("../components/Avatar", () => ({ Avatar: () => <span>头像</span> }));
const comment = (id: number, replyTo: string | null = null): PostComment => ({ id, post_id: "1", body: `正文${id}`, author_id: "reader", author: { id: "reader", username: "reader", nickname: "读者", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01" }, created_at: "2026-09-08T00:00:00Z", images: [], media_id: null, media: null, reply_to: replyTo, is_author: false });
const props = { onSend: vi.fn(), onDelete: vi.fn(), onReply: vi.fn(), onReplyClear: vi.fn(), replyTarget: null, hideComposer: true };
const animate = vi.fn(() => ({ cancel: vi.fn(), onfinish: null }));
const original = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
beforeEach(() => {
  animate.mockClear();
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: animate });
});
afterEach(() => {
  if (original) Object.defineProperty(HTMLElement.prototype, "animate", original);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

describe("CommentList page entries", () => {
  it("serializes deletion per comment until its caller finishes and leaves unrelated rows usable", async () => {
    let resolve!: () => void;
    const onDelete = vi.fn(() => new Promise<void>((yes) => { resolve = yes; }));
    render(<CommentList {...props} onDelete={onDelete} comments={[{ ...comment(1), is_author: true }, comment(2)]} />);
    fireEvent.click(screen.getByRole("button", { name: "删除" }));
    const busy = screen.getByRole("button", { name: "删除中…" });
    expect(busy).toBeDisabled();
    fireEvent.click(busy);
    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(screen.getAllByRole("button", { name: "回复" })[1]).toBeEnabled();
    await act(async () => resolve());
    expect(screen.getByRole("button", { name: "删除" })).toBeEnabled();
  });
  it("only appended DOM animates; existing rows retain their nodes", () => {
    const view = render(<CommentList {...props} comments={[comment(1)]} revealItems />);
    const retained = view.container.querySelector('[data-comment-id="1"]');
    expect(animate).toHaveBeenCalledTimes(1);
    view.rerender(<CommentList {...props} comments={[comment(1), comment(2)]} revealItems />);
    expect(view.container.querySelector('[data-comment-id="1"]')).toBe(retained);
    expect(animate).toHaveBeenCalledTimes(2);
  });
  it("cached rows stay still on return and subsequent pages can enter", () => {
    const view = render(<CommentList {...props} comments={[comment(1), comment(2)]} revealItems suppressEntry />);
    expect(animate).not.toHaveBeenCalled();
    view.rerender(<CommentList {...props} comments={[comment(1), comment(2), comment(3)]} revealItems />);
    expect(animate).toHaveBeenCalledTimes(1);
  });
  it("group initial rows inherit the body entry, while later comments enter independently", () => {
    const view = render(<CommentList {...props} comments={[comment(1)]} />);
    expect(animate).not.toHaveBeenCalled();
    view.rerender(<CommentList {...props} comments={[comment(1), comment(2)]} />);
    expect(animate).toHaveBeenCalledTimes(1);
  });
  it("an unloaded reply target remains visible as a reference", () => {
    render(<CommentList {...props} comments={[comment(2, "99")]} />);
    expect(screen.getByText("回复评论 #99（未在当前列表中）")).toBeInTheDocument();
  });
});
