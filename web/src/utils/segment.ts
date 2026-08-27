/**
 * 图文混排段（segments）工具 —— 预览摘要生成（列表/引用/群活跃度共用）。
 *
 * 语义（与 backend chat/serializers.message_preview 对齐）：
 * - text 段拼原文；image 段 → [图片]；video 段 → [视频]；
 * - 输出如「文本文本[视频]文本[图片]文本文本[图片]」；
 * - 无 segments（旧消息/单媒体）返回 null，调用方走各自 fallback。
 */
import type { MediaSegment } from "../api/types";

export const SEGMENT_PLACEHOLDER: Record<string, string> = {
  image: "[图片]",
  video: "[视频]",
};

/** mention 段显示名（不含 @ 前缀）：优先服务端 user 昵称，回退乐观 name / 未知用户 */
export function mentionLabel(
  seg: { type: "mention"; user_id: string; user?: { nickname?: string; username?: string } | null; name?: string },
): string {
  return seg.user?.nickname || seg.user?.username || seg.name || "未知用户";
}

/** 混排段 → 预览摘要（无 segments 返回 null；mention 段显示 @昵称） */
export function segmentPreview(segments?: MediaSegment[] | null): string | null {
  if (!segments || segments.length === 0) return null;
  let out = "";
  for (const seg of segments) {
    if (seg.type === "text") {
      out += seg.text;
    } else if (seg.type === "mention") {
      out += `@${mentionLabel(seg)}`;
    } else {
      out += SEGMENT_PLACEHOLDER[seg.type] ?? "[媒体]";
    }
  }
  return out;
}

/** 混排段 → 纯文本部分（等价后端 content 的文本拼接；无则空串） */
export function segmentText(segments?: MediaSegment[] | null): string {
  if (!segments) return "";
  return segments
    .filter((s) => s.type === "text")
    .map((s) => (s.type === "text" ? s.text : ""))
    .join("");
}

/** 消息预览摘要：优先混排段，其次 content（单媒体/文本消息的兜底由调用方处理） */
export function messagePreviewText(
  segments?: MediaSegment[] | null,
  content?: string,
): string | null {
  const fromSegments = segmentPreview(segments);
  if (fromSegments != null) return fromSegments;
  if (content) return content;
  return null;
}
