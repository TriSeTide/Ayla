/**
 * LiveStreamAddresses —— 推流地址复制区（服务器 / 串流密钥 / FLV 地址）。
 *
 * 开播控制台放在直播视频下方展示（仅 owner 且持有推流信息时渲染）。
 * stream_key 是推流指纹：不打日志、不持久化、仅内存展示。
 */
import { useState } from "react";
import type { LiveChannelDescriptor } from "../../api/types";
import { obsServerFromRtmpUrl } from "./LiveCreate";

export function LiveStreamAddresses({
  channel,
}: {
  channel: LiveChannelDescriptor;
}) {
  const [copied, setCopied] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  if (!channel.rtmp_url || !channel.stream_key) return null;
  // 提前捕获局部常量，供事件回调里安全使用（避免 null 收窄在闭包中失效）
  const server = obsServerFromRtmpUrl(channel.rtmp_url);
  const streamKey = channel.stream_key;

  const copy = async (text: string, which: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(which);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      setError("复制失败，请手动选择复制");
    }
  };

  return (
    <div className="live-studio-stream">
      <div className="live-copy-row">
        <span className="live-copy-label">服务器</span>
        <code className="live-copy-value">{server}</code>
        <button
          type="button"
          className="msg-action-btn"
          onClick={() => void copy(server, "server")}
        >
          {copied === "server" ? "已复制" : "复制"}
        </button>
      </div>
      <div className="live-copy-row">
        <span className="live-copy-label">串流密钥</span>
        <code className="live-copy-value">{streamKey}</code>
        <button
          type="button"
          className="msg-action-btn"
          onClick={() => void copy(streamKey, "key")}
        >
          {copied === "key" ? "已复制" : "复制"}
        </button>
      </div>
      <div className="live-copy-row">
        <span className="live-copy-label">FLV 地址</span>
        <code className="live-copy-value">{channel.flv_url}</code>
        <button
          type="button"
          className="msg-action-btn"
          onClick={() => void copy(channel.flv_url, "flv")}
        >
          {copied === "flv" ? "已复制" : "复制"}
        </button>
      </div>
      {error && <div className="live-form-error">{error}</div>}
    </div>
  );
}
