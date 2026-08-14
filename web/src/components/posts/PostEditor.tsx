/**
 * PostEditor —— 发帖表单（R-F3 / R-P2 / 群内 R-G5）。
 *
 * 字段（本期最小集）：标题（可选）+ 正文（必填）；图片上传前端链路后置（§7）。
 * 提交中禁用防重复；失败展示错误并保留已填内容。一级 tab 走 FAB、群内走底部输入框，
 * 两条路径复用本编辑器（group 归属由调用方传入）。
 */
import { useState } from "react";
import * as postsApi from "../../api/posts";
import type { Post } from "../../api/types";

export function PostEditor({
  group,
  onCreated,
  compact = false,
}: {
  /** 群内发帖归属的群 id；一级 tab 为 null（公开） */
  group?: string | null;
  onCreated: (post: Post) => void;
  /** 紧凑模式（群内底部输入框变体：单行正文，无标题） */
  compact?: boolean;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = body.trim();
    if (!trimmed) {
      setError("正文不能为空");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const post = await postsApi.createPost({
        title: title.trim(),
        body: trimmed,
        group,
      });
      setTitle("");
      setBody("");
      onCreated(post);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发布失败");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="post-editor">
      {!compact && (
        <input
          className="field post-editor-title"
          placeholder="标题（可选）"
          value={title}
          maxLength={128}
          onChange={(e) => setTitle(e.target.value)}
        />
      )}
      <textarea
        className="field post-editor-body"
        placeholder={compact ? "发一条帖子…" : "正文（必填）"}
        value={body}
        rows={compact ? 1 : 4}
        onChange={(e) => setBody(e.target.value)}
      />
      {error && <p className="post-editor-error">{error}</p>}
      <button
        type="button"
        className="btn btn-primary post-editor-submit"
        disabled={submitting || !body.trim()}
        onClick={() => void submit()}
      >
        {submitting ? "发布中…" : "发布"}
      </button>
    </div>
  );
}
