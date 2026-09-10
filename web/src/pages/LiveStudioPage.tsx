/**
 * LiveStudioPage —— 主播开播控制台（/live/start/:channelId）。
 *
 * 与普通直播间共用视频和弹幕，但主播面板只在这里出现；离开页面后，
 * 已开播的活动态会保留一个返回入口，避免主播找不到控制台。
 * 侧栏提供删除/新建直播间（仅自己拥有的频道）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as liveApi from "../api/live";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveRoomBody } from "../components/live/LiveRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { useLiveStore } from "../stores/live";
import { useShellStore } from "../stores/shell";
import { sortLiveChannels } from "../utils/sortChannels";
import { useOwnedLiveDirectory } from "../hooks/useOwnedLiveDirectory";
import { useAuthStore } from "../stores/auth";

export function LiveStudioPage() {
  const navigate = useNavigate();
  const { channelId: rawChannelId } = useParams<{ channelId: string }>();
  const channelId = Number(rawChannelId);
  const validId = Number.isInteger(channelId) && channelId > 0;
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { inputEntered } = useEnterRoomAnimation();
  const channel = useLiveStore((s) => s.current.channel);
  const directory = useOwnedLiveDirectory();
  const owner = useAuthStore((state) => state.currentUser?.id ?? "");
  const currentOwner = useRef(owner);
  currentOwner.current = owner;
  const ordered = directory.items;
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const listLoaded = directory.loaded;
  // ref 始终持有最新 ordered，供删除/新建事件回调使用（避免连续操作读到旧闭包）
  const orderedRef = useRef<LiveChannelDescriptor[]>([]);
  orderedRef.current = ordered;
  // 统一入口：所有来源（store 同步 / 重拉 / 删除重算 / 新建）都经此写入，
  // 并统一套直播新排序（在播 > 曾播 > 从未，事实源 = 后端 started_at/ended_at）。
  const applyOrdered = useCallback((next: LiveChannelDescriptor[]) => {
    const sorted = sortLiveChannels(next);
    orderedRef.current = sorted;
    directory.updateItems(() => sorted);
  }, [directory.updateItems]);
  // ref 始终持有最新当前频道 id（渲染后同步），避免连续删除回调读到旧 channelId 闭包
  const channelIdRef = useRef(channelId);
  channelIdRef.current = channelId;
  useEffect(() => { setDeletingId(null); }, [owner]);

  // 当前频道详情更新（保存资料/封面、开播状态等）→ 同步到侧栏列表项，保证封面实时刷新；
  // 状态/时间戳变化（开播/下播）后同样按新排序归位。
  useEffect(() => {
    if (!channel) return;
    directory.updateItems((prev) => {
      if (!prev.some((c) => c.id === channel.id)) return prev;
      const next = sortLiveChannels(prev.map((c) => (c.id === channel.id ? channel : c)));
      orderedRef.current = next;
      return next;
    });
  }, [channel, directory.updateItems]);

  useEffect(() => {
    if (!validId) navigate("/live", { replace: true });
  }, [validId, navigate]);

  useEffect(() => {
    if (!validId) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [validId]);

  const handleDeleteChannel = async (targetId: number) => {
    setDeletingId(targetId);
    try {
      await liveApi.deleteLiveChannel(targetId);
      if (currentOwner.current !== owner) return;
      directory.invalidate();
      useLiveStore.getState().removeChannel(targetId);
      // Refresh one bounded owner page; a missing unloaded item never means it was deleted.
      let mine: LiveChannelDescriptor[] = orderedRef.current.filter((item) => item.id !== targetId);
      applyOrdered(mine);
      const firstPage = await directory.refreshPage();
      if (currentOwner.current !== owner) return;
      if (firstPage) mine = firstPage.results;
      // 当前频道已被删除（不在最新列表）：跳到列表里相邻的下一个（保持相对位置），
      // 继续留在开播界面；删空则留在原地由空态接管（暂无直播间 + 创建按钮），不回直播列表
      const currentId = channelIdRef.current;
      if (currentId === targetId) {
        if (mine.length > 0) {
          const idx = orderedRef.current.findIndex((c) => c.id === targetId);
          const next = mine[Math.min(idx < 0 ? 0 : idx, mine.length - 1)];
          navigate(`/live/start/${next.id}`, { replace: true });
        }
      }
    } catch {
      // 删除失败静默
    } finally {
      if (currentOwner.current === owner) setDeletingId(null);
    }
  };

  const handleCreateNewChannel = async () => {
    try {
      const created = await liveApi.createLiveChannel("新直播间");
      if (currentOwner.current !== owner) return;
      directory.invalidate();
      // 新建后立即加入侧栏列表（同组件不重挂载，loadedRef 不会重置），并进入新频道控制台
      applyOrdered([created, ...orderedRef.current.filter((item) => item.id !== created.id)]);
      navigate(`/live/start/${created.id}`, { replace: true });
    } catch {
      // 创建失败静默
    }
  };

  if (!validId) return null;

  // 列表已加载且没有任何直播间：留在开播界面显示空态（创建入口），不渲染 LiveRoomBody
  if (listLoaded && !directory.loading && !directory.error && !directory.hasMore && ordered.length === 0) {
    return (
      <>
        <div className="live-studio-empty">
          <p className="live-studio-empty-title">暂无直播间</p>
          <p className="live-studio-empty-desc">创建你的第一个直播间，开始推流吧</p>
          <button
            type="button"
            className="btn btn-glow"
            onClick={() => void handleCreateNewChannel()}
          >
            创建直播间
          </button>
        </div>
      </>
    );
  }

  return (
    <>
      <LiveRoomBody
        channelId={channelId}
        channel={channel}
        isNarrow={isNarrow}
        channels={ordered}
        onSelect={(id) => navigate(`/live/start/${id}`, { replace: true })}
        onBack={() => navigate(-1)}
        inputEntered={inputEntered}
        showOwnerPanel={Boolean(channel?.is_owner)}
        activityRoute={`/live/start/${channelId}`}
        keepLiveActivity
        onDeleteChannel={channel?.is_owner ? (id) => void handleDeleteChannel(id) : undefined}
        onCreateNewChannel={channel?.is_owner ? () => void handleCreateNewChannel() : undefined}
        deletingChannelId={deletingId}
        directory={{ ...directory, onScroll: (element) => {
          if (!directory.loading && !directory.error && !directory.invalidated && directory.hasMore
            && element.scrollHeight - element.scrollTop - element.clientHeight < 240) void directory.loadMore();
        } }}
      />
    </>
  );
}
