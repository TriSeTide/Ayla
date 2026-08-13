/**
 * LiveOwnerPanel —— 主播面板（M5-4，文档 §4.5）。
 *
 * 仅 owner 渲染：推流地址复制（rtmp 服务器 + 串流密钥 + flv 备用地址）、
 * :start 开播 / :stop 下播 / 删除频道（直播中删除被后端 400 拦截，提示"请先下播"）。
 * 状态语义：srsStatus=live 才显示下播；乐观已开播但 SRS 无流时提示"等待推流信号"。
 */
import { useState } from "react";
import * as liveApi from "../../api/live";
import type { LiveChannelDescriptor, LiveSrsStatus } from "../../api/types";
import { useLiveStore } from "../../stores/live";
import { obsServerFromRtmpUrl } from "./LiveCreate";

export function LiveOwnerPanel({
  channel,
  srsStatus,
  onDeleted,
}: {
  channel: LiveChannelDescriptor;
  srsStatus: LiveSrsStatus | null;
  onDeleted: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const copy = async (text: string, which: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(which);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      setError("复制失败，请手动选择复制");
    }
  };

  const run = async (action: () => Promise<LiveChannelDescriptor>) => {
    setBusy(true);
    setError(null);
    try {
      const updated = await action();
      useLiveStore.getState().setCurrentChannel(updated);
      useLiveStore.getState().upsertChannel(updated);
    } catch (e) {
      setError(e instanceof Error ? e.message : "操作失败");
    } finally {
      setBusy(false);
    }
  };

  const handleDelete = async () => {
    setBusy(true);
    setError(null);
    try {
      await liveApi.deleteLiveChannel(channel.id);
      useLiveStore.getState().removeChannel(channel.id);
      onDeleted();
    } catch (e) {
      // 直播中删除 → 400「直播中禁止删除，请先 :stop」原样展示
      setError(e instanceof Error ? e.message : "删除失败");
    } finally {
      setBusy(false);
    }
  };

  const waitingSignal = channel.status === "live" && srsStatus !== "live";

  return (
    <div className="live-owner-panel">
      <div className="live-owner-title">主播面板</div>

      {channel.rtmp_url && channel.stream_key && (
        <div className="live-owner-stream">
          <div className="live-copy-row">
            <span className="live-copy-label">服务器</span>
            <code className="live-copy-value">
              {obsServerFromRtmpUrl(channel.rtmp_url)}
            </code>
            <button
              type="button"
              className="msg-action-btn"
              onClick={() => void copy(obsServerFromRtmpUrl(channel.rtmp_url!), "server")}
            >
              {copied === "server" ? "已复制" : "复制"}
            </button>
          </div>
          <div className="live-copy-row">
            <span className="live-copy-label">串流密钥</span>
            <code className="live-copy-value">{channel.stream_key}</code>
            <button
              type="button"
              className="msg-action-btn"
              onClick={() => void copy(channel.stream_key!, "key")}
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
        </div>
      )}

      <div className="live-owner-actions">
        {channel.status !== "live" ? (
          <button
            type="button"
            className="btn btn-glow"
            disabled={busy}
            onClick={() => void run(() => liveApi.startLiveChannel(channel.id))}
          >
            开播
          </button>
        ) : (
          <button
            type="button"
            className="btn"
            disabled={busy}
            onClick={() => void run(() => liveApi.stopLiveChannel(channel.id))}
          >
            下播
          </button>
        )}
        <button
          type="button"
          className="msg-action-btn live-danger"
          disabled={busy}
          onClick={() => void handleDelete()}
        >
          删除频道
        </button>
      </div>

      {waitingSignal && (
        <div className="live-owner-waiting">已标记开播，等待推流信号…</div>
      )}
      {error && <div className="live-form-error">{error}</div>}
    </div>
  );
}
