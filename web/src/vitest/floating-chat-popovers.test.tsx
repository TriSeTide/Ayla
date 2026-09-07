import { fireEvent, render, screen } from "@testing-library/react";
import { useRef, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationMember, UserPublic } from "../api/types";
import { ConversationMoreMenu } from "../components/chat/ConversationMoreMenu";
import { MentionPicker } from "../components/chat/MentionPicker";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { useAuthStore } from "../stores/auth";

const self: UserPublic = { id: "self", username: "self", nickname: "自己", avatar: "", signature: "", status: "auto", online: true, date_joined: "" };
const members: ConversationMember[] = ["小明", "小红"].map((nickname, index) => ({
  id: `member-${index}`, user: { ...self, id: `user-${index}`, nickname }, role: "member", muted: false, joined_at: "",
}));
beforeEach(() => { useAuthStore.setState({ currentUser: self, accessToken: "test" }); });

describe("conversation menu portal interaction", () => {
  it("Escape closes only the top menu before an earlier document drawer handler can run", () => {
    const backgroundClose = vi.fn();
    const onBackground = (event: KeyboardEvent) => { if (event.key === "Escape") backgroundClose(); };
    document.addEventListener("keydown", onBackground);
    try {
      render(<ConversationMoreMenu conversation={{ id: "nested", title: "抽屉会话" }} />);
      fireEvent.click(screen.getByRole("button", { name: "抽屉会话 的更多操作" }));
      fireEvent.keyDown(document.activeElement!, { key: "Escape" });
      expect(backgroundClose).not.toHaveBeenCalled();
      expect(screen.getByRole("button", { name: "抽屉会话 的更多操作" })).toHaveFocus();
    } finally { document.removeEventListener("keydown", onBackground); }
  });
  it("leaves the clipped row and supports arrow keys and Escape focus restoration", () => {
    const { container } = render(<div style={{ overflow: "hidden" }}><ConversationMoreMenu conversation={{ id: "one", title: "会话" }} /></div>);
    const trigger = screen.getByRole("button", { name: "会话 的更多操作" });
    trigger.focus(); fireEvent.keyDown(trigger, { key: "ArrowDown" });
    const menu = screen.getByRole("menu");
    expect(menu.parentElement).toBe(document.body);
    expect(container.contains(menu)).toBe(false);
    expect(screen.getByRole("menuitem", { name: "置顶" })).toHaveFocus();
    fireEvent.keyDown(document.activeElement!, { key: "ArrowUp" });
    expect(screen.getByRole("menuitem", { name: "删除会话" })).toHaveFocus();
    fireEvent.keyDown(document.activeElement!, { key: "Home" });
    expect(screen.getByRole("menuitem", { name: "置顶" })).toHaveFocus();
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it("keeps internal pointer events in the portal, closes on outside pointer or parent scroll", () => {
    const { container } = render(<div><ConversationMoreMenu conversation={{ id: "two", title: "会话" }} /><button>外部按钮</button></div>);
    const trigger = screen.getByRole("button", { name: "会话 的更多操作" });
    fireEvent.click(trigger);
    fireEvent.pointerDown(screen.getByRole("menuitem", { name: "置顶" }));
    expect(screen.getByRole("menu")).toBeInTheDocument();
    fireEvent.pointerDown(screen.getByRole("button", { name: "外部按钮" }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(trigger); fireEvent.scroll(container);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});

describe("confirmation inside a drawer", () => {
  it("Escape does not dismiss its background drawer and Tab stays in the modal", () => {
    const backgroundClose = vi.fn(), close = vi.fn();
    const onBackground = (event: KeyboardEvent) => { if (event.key === "Escape") backgroundClose(); };
    document.addEventListener("keydown", onBackground);
    try {
      render(<ConfirmDialog title="删除会话" message="确认？" onClose={close} onConfirm={vi.fn()} />);
      const first = screen.getByRole("button", { name: "关闭" });
      const last = screen.getByRole("button", { name: /^删除$/ });
      first.focus(); fireEvent.keyDown(first, { key: "Tab", shiftKey: true });
      expect(last).toHaveFocus();
      fireEvent.keyDown(last, { key: "Tab" }); expect(first).toHaveFocus();
      fireEvent.keyDown(first, { key: "Escape" });
      expect(close).toHaveBeenCalledTimes(1);
      expect(backgroundClose).not.toHaveBeenCalled();
    } finally { document.removeEventListener("keydown", onBackground); }
  });
});

function AnchoredMention({ onSelect }: { onSelect: (member: ConversationMember) => void }) {
  const editor = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(true);
  return <div className="composer"><div ref={editor} contentEditable role="textbox" aria-label="编辑器" />
    {open && <MentionPicker members={members} query="" anchorRef={editor} onSelect={onSelect} onClose={() => setOpen(false)} />}
    <button>其他操作</button>
  </div>;
}

describe("mention portal preserves editor selection flow", () => {
  it("escapes the composer, keyboard selects members and Escape returns to the editor", () => {
    const selected = vi.fn();
    render(<AnchoredMention onSelect={selected} />);
    expect(screen.getByRole("listbox").parentElement).toBe(document.body);
    const editor = screen.getByRole("textbox", { name: "编辑器" });
    editor.focus(); fireEvent.keyDown(editor, { key: "ArrowDown" });
    expect(screen.getByRole("option", { name: "@小明" })).toHaveFocus();
    fireEvent.keyDown(document.activeElement!, { key: "ArrowDown" });
    expect(screen.getByRole("option", { name: "@小红" })).toHaveFocus();
    fireEvent.click(document.activeElement!);
    expect(selected).toHaveBeenCalledWith(members[1]);
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
    expect(editor).toHaveFocus();
  });

  it("outside pointer closes the dropdown without requiring a selection", () => {
    render(<AnchoredMention onSelect={vi.fn()} />);
    fireEvent.pointerDown(screen.getByRole("button", { name: "其他操作" }));
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
  });
});
