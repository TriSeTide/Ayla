/**
 * LiveStartSheet —— 开播入口：选择已有直播间，或创建新的直播间。
 *
 * 这是主播专用的入口，不复制直播间数据；选择后统一进入开播控制台。
 * 列表排序与直播界面统一（sortLiveChannels：在播 > 曾播 > 从未，事实源 =
 * 后端 started_at/ended_at 字段）；并订阅 live store 的 WS 热更新——
 * 弹窗打开期间有人开播/下播/新建直播间时，本人直播间列表实时合并重排。
 */
import type { LiveChannelDescriptor } from "../../api/types";
import { useOwnedLiveDirectory } from "../../hooks/useOwnedLiveDirectory";
import { DirectoryLoadMore } from "../DirectoryLoadMore";

export function LiveStartSheet({
  onStart,
  onCreateNew,
  creatingNew = false,
  createError = null,
}: {
  onStart: (channel: LiveChannelDescriptor) => void;
  onCreateNew: () => void;
  /** 正在创建新直播间（按钮置为“创建中…”并禁用） */
  creatingNew?: boolean;
  /** 创建失败的错误文案（选择器内展示） */
  createError?: string | null;
}) {
  const directory = useOwnedLiveDirectory();
  const { items: channels, loading, error } = directory;

  return (
    <div className="live-start-picker">
      <div className="live-start-intro">
        <strong>选择一个直播间开始</strong>
        <span>已有直播间可以直接复用，直播画面和弹幕会在开播控制台里一起显示。</span>
      </div>

      {loading && !directory.loaded && <div className="live-start-state">正在加载你的直播间…</div>}
      {error && !directory.loaded && !creatingNew && (
        <div className="live-start-error" role="alert">
          <span>直播间列表加载失败：{error}</span>
          <button type="button" className="btn btn-ghost" onClick={() => void directory.refresh()}>
            重试
          </button>
        </div>
      )}
      {createError && (
        <div className="live-start-error" role="alert">
          <span>创建直播间失败：{createError}</span>
        </div>
      )}
      {directory.loaded && !loading && !error && !directory.invalidated && !directory.hasMore && channels.length === 0 && (
        <div className="live-start-empty">还没有自己的直播间，先创建一个吧。</div>
      )}
      {directory.loaded && (channels.length > 0 || error || directory.hasMore || directory.invalidated) && (
        <div className="live-start-list" role="list" aria-label="我的直播间">
          {channels.map((channel) => (
            <button
              key={channel.id}
              type="button"
              className="live-start-channel"
              onClick={() => onStart(channel)}
            >
              <span className="live-start-channel-cover" aria-hidden="true">
                {channel.status === "live" ? "LIVE" : ""}
              </span>
              <span className="live-start-channel-copy">
                <strong>{channel.title}</strong>
                <small>{channel.status === "live" ? "正在直播，可继续开播" : "准备开播"}</small>
              </span>
              <span className="live-start-channel-arrow" aria-hidden="true">→</span>
            </button>
          ))}
          <DirectoryLoadMore {...directory} />
        </div>
      )}

      <button
        type="button"
        className="btn btn-glow live-start-new"
        disabled={creatingNew}
        onClick={onCreateNew}
      >
        {creatingNew ? "创建中…" : "+ 添加新的直播间"}
      </button>
    </div>
  );
}
