/**
 * LiveCreate —— 创建直播频道 + 推流指引一次性回显（M5-4，文档 §4.5）。
 *
 * 创建成功后展示 OBS 指引面板：服务器 + 串流密钥两个复制框，
 * 文案明确"此信息仅本次显示"（与后端契约一致：此后仅详情页 owner 可见）。
 * stream_key 是推流指纹：不打日志、不持久化、仅内存展示。
 */
import { useState } from "react";
import * as liveApi from "../../api/live";
import type { LiveChannelDescriptor } from "../../api/types";

/** 从 rtmp_url 拆出 OBS 的"服务器"部分（去掉末尾 /<stream_key>） */
export function obsServerFromRtmpUrl(rtmpUrl: string): string {
  const idx = rtmpUrl.lastIndexOf("/");
  return idx > 0 ? rtmpUrl.slice(0, idx) : rtmpUrl;
}

export function LiveCreate({
  onCreated,
}: {
  onCreated: (channel: LiveChannelDescriptor) => void;
}) {
  const [title, setTitle] = useState("");
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
      const channel = await liveApi.createLiveChannel(trimmed);
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
        <input
          className="live-create-input"
          placeholder="给直播间起个标题"
          value={title}
          maxLength={128}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void submit();
          }}
        />
        <button
          type="button"
          className="btn btn-glow"
          disabled={creating}
          onClick={() => void submit()}
        >
          {creating ? "创建中…" : "开播"}
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
