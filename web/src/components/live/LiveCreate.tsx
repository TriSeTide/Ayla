/**
 * LiveCreate —— 创建直播频道 + 推流指引一次性回显（M5-4，文档 §4.5）。
 *
 * 创建成功后展示 OBS 指引面板：服务器 + 串流密钥两个复制框，
 * 文案明确"此信息仅本次显示"（与后端契约一致：此后仅详情页 owner 可见）。
 * stream_key 是推流指纹：不打日志、不持久化、仅内存展示。
 */
import { useRef, useState } from "react";
import * as liveApi from "../../api/live";
import { mediaContentUrl, uploadMediaFile, validateAvatarFile } from "../../api/media";
import type { LiveChannelDescriptor } from "../../api/types";
import { VisibilitySelector, type VisibilityValue } from "../VisibilitySelector";

/** 从 rtmp_url 拆出 OBS 的"服务器"部分（去掉末尾 /<stream_key>） */
export function obsServerFromRtmpUrl(rtmpUrl: string): string {
  const idx = rtmpUrl.lastIndexOf("/");
  return idx > 0 ? rtmpUrl.slice(0, idx) : rtmpUrl;
}

export function LiveCreate({
  onCreated,
  group,
}: {
  onCreated: (channel: LiveChannelDescriptor) => void;
  /** 群内创建时归属的群 id（一级 tab 创建为 null，R-F2） */
  group?: string | null;
}) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [visibility, setVisibility] = useState<VisibilityValue>(group ? "group" : "public");
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>(group ? [group] : []);
  const [coverFile, setCoverFile] = useState<File | null>(null);
  const [coverPreview, setCoverPreview] = useState<string | null>(null);
  const coverInputRef = useRef<HTMLInputElement>(null);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** 创建成功的频道（一次性回显推流信息） */
  const [created, setCreated] = useState<LiveChannelDescriptor | null>(null);
  const [copied, setCopied] = useState<"server" | "key" | null>(null);

  const submit = async () => {
    const trimmed = title.trim();
    if (!trimmed) {
      setError("标题不能为空");
      return;
    }
    setCreating(true);
    setError(null);
    try {
      let cover = "";
      if (coverFile) {
        const uploaded = await uploadMediaFile(coverFile, "image");
        cover = mediaContentUrl(uploaded.media_id);
      }
      const channel = await liveApi.createLiveChannel(trimmed, group, {
        description: description.trim(),
        cover,
        visibility,
        allowed_group_ids: selectedGroupIds,
      });
      setCreated(channel);
      setTitle("");
      onCreated(channel);
    } catch (e) {
      setError(e instanceof Error ? e.message : "创建失败");
    } finally {
      setCreating(false);
    }
  };

  const copy = async (text: string, which: "server" | "key") => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(which);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      setError("复制失败，请手动选择复制");
    }
  };

  return (
    <div className="live-create">
      <div className="live-create-form">
        <label className="live-field-label">
          标题
          <input
            className="live-create-input"
            placeholder="给直播间起个标题"
            value={title}
            maxLength={128}
            onChange={(e) => setTitle(e.target.value)}
          />
        </label>
        <label className="live-field-label">
          介绍
          <textarea
            className="live-create-input live-create-textarea"
            placeholder="告诉观众这场直播聊什么（可选）"
            value={description}
            maxLength={2000}
            onChange={(e) => setDescription(e.target.value)}
          />
        </label>
        <VisibilitySelector value={visibility} onChange={setVisibility} selectedGroupIds={selectedGroupIds} onSelectedGroupIdsChange={setSelectedGroupIds} initialGroupId={group} />
        <div className="live-cover-field">
          <span className="live-field-label">封面</span>
          <button type="button" className="live-cover-picker" onClick={() => coverInputRef.current?.click()}>
            {coverPreview ? <img src={coverPreview} alt="直播间封面预览" /> : <span>选择 16:9 封面图片</span>}
          </button>
          <input
            ref={coverInputRef}
            className="visually-hidden"
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp"
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              const invalid = validateAvatarFile(file);
              if (invalid) {
                setError(invalid);
                return;
              }
              setError(null);
              setCoverFile(file);
              setCoverPreview(URL.createObjectURL(file));
            }}
          />
        </div>
        <button
          type="button"
          className="btn btn-glow"
          disabled={creating}
          onClick={() => void submit()}
        >
          {creating ? "准备中…" : "开播"}
        </button>
      </div>
      {error && <div className="live-form-error">{error}</div>}

      {created && created.stream_key && created.rtmp_url && (
        <div className="live-create-guide">
          <div className="live-create-guide-title">
            直播间「{created.title}」已创建
          </div>
          <p className="live-create-guide-notice">
            推流信息仅本次显示，请立即复制到 OBS（此后可在直播间详情页查看）。
          </p>
          <div className="live-copy-row">
            <span className="live-copy-label">服务器</span>
            <code className="live-copy-value">
              {obsServerFromRtmpUrl(created.rtmp_url)}
            </code>
            <button
              type="button"
              className="msg-action-btn"
              onClick={() => void copy(obsServerFromRtmpUrl(created.rtmp_url!), "server")}
            >
              {copied === "server" ? "已复制" : "复制"}
            </button>
          </div>
          <div className="live-copy-row">
            <span className="live-copy-label">串流密钥</span>
            <code className="live-copy-value">{created.stream_key}</code>
            <button
              type="button"
              className="msg-action-btn"
              onClick={() => void copy(created.stream_key!, "key")}
            >
              {copied === "key" ? "已复制" : "复制"}
            </button>
          </div>
          <button
            type="button"
            className="msg-action-btn live-guide-dismiss"
            onClick={() => setCreated(null)}
          >
            我已保存，关闭
          </button>
        </div>
      )}
    </div>
  );
}
