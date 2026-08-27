/**
 * @ 能力工具（M8）：编辑器草稿块 ↔ DOM ↔ 字符串 的纯函数 + contentEditable 光标操作。
 *
 * 输入模型：contentEditable 编辑器产出 DraftBlock[]（text 与 mention 交错），
 * mention 在 DOM 里是 `contenteditable=false` 的 span（浏览器原生整体删除）；
 * 草稿（chatDrafts）序列化为 `@[<user_id>]` 标记的纯字符串。
 */
import type { DraftBlock } from "../api/types";

/* ---------- blocks 派生（发送用） ---------- */

/** DraftBlock[] → 纯文本（等价后端 content：仅 text 块拼接，mention 不进 content） */
export function blocksText(blocks: DraftBlock[]): string {
  return blocks
    .filter((b): b is { type: "text"; text: string } => b.type === "text")
    .map((b) => b.text)
    .join("");
}

/** 是否含 mention 块 */
export function blocksHasMention(blocks: DraftBlock[]): boolean {
  return blocks.some((b) => b.type === "mention");
}

/** DraftBlock[] → 发送 payload 的 segments 前缀（text/mention 段；媒体段由 picked 追加在尾部） */
export function blocksToSegments(
  blocks: DraftBlock[],
): Array<{ type: "text"; text: string } | { type: "mention"; user_id: string }> {
  return blocks.map((b) =>
    b.type === "text"
      ? { type: "text" as const, text: b.text }
      : { type: "mention" as const, user_id: b.user_id },
  );
}

/* ---------- 草稿序列化 / 解析 ---------- */

/** blocks → 草稿字符串（mention → `@[user_id]`） */
export function serializeBlocks(blocks: DraftBlock[]): string {
  return blocks.map((b) => (b.type === "text" ? b.text : `@[${b.user_id}]`)).join("");
}

/** 草稿字符串 → blocks（nameOf 提供 user_id → 显示名；查不到回退「未知用户」） */
export function parseBlocks(
  str: string,
  nameOf: (id: string) => string | undefined,
): DraftBlock[] {
  const blocks: DraftBlock[] = [];
  const re = /@\[([^\]]+)\]/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(str)) !== null) {
    if (m.index > last) blocks.push({ type: "text", text: str.slice(last, m.index) });
    blocks.push({ type: "mention", user_id: m[1], name: nameOf(m[1]) ?? "未知用户" });
    last = m.index + m[0].length;
  }
  if (last < str.length) blocks.push({ type: "text", text: str.slice(last) });
  return blocks;
}

/* ---------- 编辑器 DOM ↔ blocks ---------- */

/** 编辑器 DOM → blocks（text 与 mention span 交错；过滤零宽占位符） */
export function extractBlocks(el: HTMLElement): DraftBlock[] {
  const blocks: DraftBlock[] = [];
  const pushText = (raw: string) => {
    const t = raw.replace(/\u200B/g, "");
    if (!t) return;
    const last = blocks[blocks.length - 1];
    if (last && last.type === "text") last.text += t;
    else blocks.push({ type: "text", text: t });
  };
  for (const node of Array.from(el.childNodes)) {
    if (node.nodeType === Node.TEXT_NODE) {
      pushText(node.textContent ?? "");
    } else if (node instanceof HTMLElement && node.dataset.mentionId) {
      blocks.push({
        type: "mention",
        user_id: node.dataset.mentionId,
        name: node.dataset.mentionName || "未知用户",
      });
    } else if (node instanceof HTMLElement) {
      if (node.tagName === "BR") pushText("\n");
      else pushText(node.textContent ?? "");
    }
  }
  return blocks;
}

/** blocks → 编辑器 DOM（初始化/恢复草稿用） */
export function renderBlocksToDOM(el: HTMLElement, blocks: DraftBlock[]): void {
  el.innerHTML = "";
  for (const b of blocks) {
    if (b.type === "text") {
      el.appendChild(document.createTextNode(b.text));
    } else {
      const span = document.createElement("span");
      span.setAttribute("contenteditable", "false");
      span.className = "mention-token mention-token-input";
      span.dataset.mentionId = b.user_id;
      span.dataset.mentionName = b.name;
      span.textContent = `@${b.name}`;
      el.appendChild(span);
    }
  }
}

/* ---------- 光标操作 ---------- */

/** 检测光标前是否处于 @ 触发态：返回 @ 之后的过滤词（空 = 刚输入 @），否则 null */
export function detectMentionAtCaret(editor: HTMLElement): { query: string } | null {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return null;
  const range = sel.getRangeAt(0);
  const node = range.startContainer;
  if (node.nodeType !== Node.TEXT_NODE) return null;
  if (!editor.contains(node)) return null; // 光标须在本编辑器内
  const offset = range.startOffset;
  const text = node.textContent ?? "";
  const before = text.slice(0, offset);
  const atIdx = before.lastIndexOf("@");
  if (atIdx < 0) return null;
  const beforeAt = before[atIdx - 1];
  if (beforeAt !== undefined && !/[\s\n]/.test(beforeAt)) return null; // @ 前须为边界（行首/空格）
  const query = before.slice(atIdx + 1);
  if (/[\s\n]/.test(query)) return null; // @ 名不含空白
  return { query };
}

/** 在光标处把 `@query` 替换为 mention span（整体删除由 contenteditable=false 原生支持） */
export function insertMentionAtCaret(editor: HTMLElement, user_id: string, name: string): void {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return;
  const range = sel.getRangeAt(0);
  const node = range.startContainer;
  if (node.nodeType !== Node.TEXT_NODE) return;
  if (!editor.contains(node)) return; // 光标须在本编辑器内
  const offset = range.startOffset;
  const text = node.textContent ?? "";
  const before = text.slice(0, offset);
  const atIdx = before.lastIndexOf("@");
  if (atIdx < 0) return;

  const after = text.slice(offset);
  node.textContent = before.slice(0, atIdx); // @ 之前保留

  const span = document.createElement("span");
  span.setAttribute("contenteditable", "false");
  span.className = "mention-token mention-token-input";
  span.dataset.mentionId = user_id;
  span.dataset.mentionName = name;
  span.textContent = `@${name}`;

  const parent = node.parentNode;
  if (!parent) return;
  const spaceNode = document.createTextNode("\u200B"); // 零宽占位防 text node 塌缩
  const afterNode = document.createTextNode(after);
  parent.insertBefore(span, node.nextSibling);
  parent.insertBefore(spaceNode, span.nextSibling);
  parent.insertBefore(afterNode, spaceNode.nextSibling);

  const newRange = document.createRange();
  newRange.setStart(afterNode, 0);
  newRange.collapse(true);
  sel.removeAllRanges();
  sel.addRange(newRange);
}
