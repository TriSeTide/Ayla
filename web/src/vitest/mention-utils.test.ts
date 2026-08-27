import { afterEach, describe, expect, it, vi } from "vitest";
import {
  blocksHasMention,
  blocksText,
  blocksToSegments,
  detectMentionAtCaret,
  extractBlocks,
  parseBlocks,
  renderBlocksToDOM,
  serializeBlocks,
} from "../utils/mention";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("mention 工具（M8 @ 能力）", () => {
  it("blocksText 仅拼接 text 块（mention 不进 content）", () => {
    expect(
      blocksText([
        { type: "text", text: "hello " },
        { type: "mention", user_id: "u1", name: "张三" },
        { type: "text", text: " 看这个" },
      ]),
    ).toBe("hello  看这个");
    expect(blocksText([])).toBe("");
  });

  it("blocksHasMention 判定是否含 @ 块", () => {
    expect(blocksHasMention([{ type: "text", text: "hi" }])).toBe(false);
    expect(blocksHasMention([{ type: "mention", user_id: "u1", name: "张三" }])).toBe(true);
  });

  it("blocksToSegments 生成发送 payload 段（mention 只带 user_id 不带 name）", () => {
    expect(
      blocksToSegments([
        { type: "text", text: "hi " },
        { type: "mention", user_id: "u1", name: "张三" },
      ]),
    ).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u1" },
    ]);
  });

  it("serializeBlocks 把 mention 序列化为 @[user_id]，parseBlocks 反解回块", () => {
    const blocks = [
      { type: "text" as const, text: "hi " },
      { type: "mention" as const, user_id: "u1", name: "张三" },
      { type: "text" as const, text: " 你好" },
    ];
    const s = serializeBlocks(blocks);
    expect(s).toBe("hi @[u1] 你好");
    const nameOf = (id: string) => (id === "u1" ? "张三" : undefined);
    expect(parseBlocks(s, nameOf)).toEqual(blocks);
  });

  it("parseBlocks 对未知 user_id 回退「未知用户」", () => {
    const parsed = parseBlocks("hi @[ghost]", () => undefined);
    expect(parsed).toEqual([
      { type: "text", text: "hi " },
      { type: "mention", user_id: "ghost", name: "未知用户" },
    ]);
  });

  it("extractBlocks 从 DOM 提取 text 与 mention span 交错（过滤零宽占位）", () => {
    const el = document.createElement("div");
    el.appendChild(document.createTextNode("hello "));
    const span = document.createElement("span");
    span.dataset.mentionId = "u1";
    span.dataset.mentionName = "张三";
    span.textContent = "@张三";
    el.appendChild(span);
    el.appendChild(document.createTextNode("\u200B 你好"));
    expect(extractBlocks(el)).toEqual([
      { type: "text", text: "hello " },
      { type: "mention", user_id: "u1", name: "张三" },
      { type: "text", text: " 你好" },
    ]);
  });

  it("renderBlocksToDOM 把 blocks 渲染为 DOM（mention → contenteditable span）", () => {
    const el = document.createElement("div");
    renderBlocksToDOM(el, [
      { type: "text", text: "hi " },
      { type: "mention", user_id: "u1", name: "张三" },
    ]);
    expect(el.childNodes).toHaveLength(2);
    expect(el.childNodes[0].textContent).toBe("hi ");
    const span = el.childNodes[1] as HTMLElement;
    expect(span.dataset.mentionId).toBe("u1");
    expect(span.dataset.mentionName).toBe("张三");
    expect(span.textContent).toBe("@张三");
    expect(span.getAttribute("contenteditable")).toBe("false");
  });

  it("renderBlocksToDOM/extractBlocks 往返一致", () => {
    const blocks = [
      { type: "text" as const, text: "a " },
      { type: "mention" as const, user_id: "u1", name: "张三" },
      { type: "text" as const, text: " b" },
    ];
    const el = document.createElement("div");
    renderBlocksToDOM(el, blocks);
    expect(extractBlocks(el)).toEqual(blocks);
  });
});

describe("detectMentionAtCaret（任意位置 / 多次 @）", () => {
  function mockCaret(editor: HTMLElement, textNode: Text, offset: number) {
    vi.stubGlobal("getSelection", () => ({
      rangeCount: 1,
      getRangeAt: () => ({ startContainer: textNode, startOffset: offset }),
    }));
    return editor;
  }

  it("文本中间输入 @ 也能触发（任意位置，不要求 @ 前为空白）", () => {
    const editor = document.createElement("div");
    const textNode = document.createTextNode("你好@");
    editor.appendChild(textNode);
    mockCaret(editor, textNode, 3); // 光标在「你好@」之后
    expect(detectMentionAtCaret(editor)).toEqual({ query: "" });
  });

  it("连续 @：@Token 后的零宽空格不影响再次触发", () => {
    const editor = document.createElement("div");
    const textNode = document.createTextNode("\u200B@李四");
    editor.appendChild(textNode);
    mockCaret(editor, textNode, 4); // 光标在「@李四」之后
    expect(detectMentionAtCaret(editor)).toEqual({ query: "李四" });
  });

  it("@ 后到光标间有空白则视为输入中，不触发", () => {
    const editor = document.createElement("div");
    const textNode = document.createTextNode("a@b c");
    editor.appendChild(textNode);
    mockCaret(editor, textNode, 5); // 光标在末尾，「@b c」含空白
    expect(detectMentionAtCaret(editor)).toBeNull();
  });
});
