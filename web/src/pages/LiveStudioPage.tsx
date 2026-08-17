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

export function LiveStudioPage() {
  const navigate = useNavigate();
  const { channelId: rawChannelId } = useParams<{ channelId: string }>();
  const channelId = Number(rawChannelId);
  const validId = Number.isInteger(channelId) && channelId > 0;
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { inputEntered } = useEnterRoomAnimation();
  const channel = useLiveStore((s) => s.current.channel);
  const [ordered, setOrdered] = useState<LiveChannelDescriptor[]>([]);
  const [listError, setListError] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const loadedRef = useRef(false);
  const [listLoaded, setListLoaded] = useState(false);
  const [retry, setRetry] = useState(0);
  // ref 始终持有最新 ordered，供删除/新建事件回调使用（避免连续操作读到旧闭包）
  const orderedRef = useRef<LiveChannelDescriptor[]>([]);
  const applyOrdered = useCallback((next: LiveChannelDescriptor[]) => {
    orderedRef.current = next;
    setOrdered(next);
  }, []);
  // ref 始终持有最新当前频道 id（渲染后同步），避免连续删除回调读到旧 channelId 闭包
  const channelIdRef = useRef(channelId);
  useEffect(() => {
    channelIdRef.current = channelId;
  }, [channelId]);

  // 当前频道详情更新（保存资料/封面、开播状态等）→ 同步到侧栏列表项，保证封面实时刷新
  useEffect(() => {
    if (!channel) return;
    setOrdered((prev) => {
      if (!prev.some((c) => c.id === channel.id)) return prev;
      const next = prev.map((c) => (c.id === channel.id ? channel : c));
      orderedRef.current = next;
      return next;
    });
  }, [channel]);

  useEffect(() => {
    if (!validId) navigate("/live", { replace: true });
  }, [validId, navigate]);

  useEffect(() => {
    if (!validId) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => useShellStore.getState().setBottomTabsLeaving(false);
  }, [validId]);

  const reloadList = useCallback(() => {
    loadedRef.current = false;
    setListError(null);
    setRetry((value) => value + 1);
  }, []);

  useEffect(() => {
    if (!validId || loadedRef.current) return;
    loadedRef.current = true;
    setListLoaded(false);
    liveApi.listLiveChannels()
      .then((list) => {
        applyOrdered(list.filter((item) => item.is_owner));
        setListError(null);
      })
      .catch((e) => setListError(e instanceof Error ? e.message : "加载直播列表失败"))
      .finally(() => setListLoaded(true));
  }, [validId, retry, applyOrdered]);

  const handleDeleteChannel = async (targetId: number) => {
    setDeletingId(targetId);
    try {
      await liveApi.deleteLiveChannel(targetId);
      useLiveStore.getState().removeChannel(targetId);
      // 以服务器最新列表为准计算跳转目标（并发删除后最可靠，避免本地状态竞态算出已删频道）
      let mine: LiveChannelDescriptor[] = orderedRef.current.filter((item) => item.id !== targetId);
      try {
        const list = await liveApi.listLiveChannels();
        mine = list.filter((item) => item.is_owner);
      } catch {
        // 重拉失败则沿用本地已删除目标的列表
      }
      applyOrdered(mine);
      // 当前频道已被删除（不在最新列表）：跳到列表里相邻的下一个（保持相对位置），
      // 继续留在开播界面；删空则留在原地由空态接管（暂无直播间 + 创建按钮），不回直播列表
      const currentId = channelIdRef.current;
      if (!mine.some((c) => c.id === currentId)) {
        if (mine.length > 0) {
          const idx = orderedRef.current.findIndex((c) => c.id === targetId);
          const next = mine[Math.min(idx < 0 ? 0 : idx, mine.length - 1)];
          navigate(`/live/start/${next.id}`, { replace: true });
        }
      }
    } catch (e) {
      // 直播中删除 → 400「直播中禁止删除，请先 :stop」；错误文案在顶部 notice 展示
      setListError(e instanceof Error ? e.message : "删除直播间失败");
    } finally {
      setDeletingId(null);
    }
  };

  const handleCreateNewChannel = async () => {
    try {
      const created = await liveApi.createLiveChannel("新直播间");
      // 新建后立即加入侧栏列表（同组件不重挂载，loadedRef 不会重置），并进入新频道控制台
      applyOrdered([created, ...orderedRef.current.filter((item) => item.id !== created.id)]);
      navigate(`/live/start/${created.id}`, { replace: true });
    } catch (e) {
      setListError(e instanceof Error ? e.message : "创建直播间失败");
    }
  };

  if (!validId) return null;

  // 列表已加载且没有任何直播间：留在开播界面显示空态（创建入口），不渲染 LiveRoomBody
  if (listLoaded && ordered.length === 0) {
    return (
      <>
        {listError && (
          <div className="chat-notice" role="alert">
            <span>{listError}</span>
            <button type="button" className="btn btn-ghost" onClick={reloadList}>
              重试
            </button>
          </div>
        )}
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
      {listError && (
        <div className="chat-notice" role="alert">
          <span>{listError}</span>
          <button type="button" className="btn btn-ghost" onClick={reloadList}>
            重试
          </button>
        </div>
      )}
      <LiveRoomBody
        channelId={channelId}
        channel={channel}
        isNarrow={isNarrow}
        channels={ordered}
        onSelect={(id) => navigate(`/live/start/${id}`, { replace: true })}
        onBack={() => navigate("/live")}
        inputEntered={inputEntered}
        showOwnerPanel
        activityRoute={`/live/start/${channelId}`}
        keepLiveActivity
        onDeleteChannel={(id) => void handleDeleteChannel(id)}
        onCreateNewChannel={() => void handleCreateNewChannel()}
        deletingChannelId={deletingId}
      />
    </>
  );
}
