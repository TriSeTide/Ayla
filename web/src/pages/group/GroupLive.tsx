/**
 * GroupLive —— 群内直播子界面（F4，R-G7）。
 *
 * 直接进入该群第一个直播间（无卡片列表）；上下滑切换范围 = **仅该群**（与一级直播
 * tab 的"全部可见"不同，R-G7/R-L3 明确区分）。无直播 → 空态 + 发起引导。
 *
 * 群内直播是 GroupPage 的 live 子界面（底栏已在顶部，无"底栏下滑走"进房动画，
 * 输入框直接显示）；宽屏同 ChannelSidebar 内容区。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as liveApi from "../../api/live";
import type { LiveChannelDescriptor } from "../../api/types";
import { CreateSheet } from "../../layout/CreateSheet";
import { LiveStartSheet } from "../../components/live/LiveStartSheet";
import { LiveRoomBody } from "../../components/live/LiveRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useLiveStore } from "../../stores/live";
import { useDirectoryPage } from "../../hooks/useDirectoryPage";

export function GroupLive({ groupId, routeChannelId, onExit }: { groupId: string; routeChannelId?: string; onExit: () => void }) {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const channel = useLiveStore((s) => s.current.channel);
  const directory = useDirectoryPage("live", { groupId });
  const { items: channels, loading, refresh: load } = directory;
  const [detailError, setDetailError] = useState<string | null>(null);
  const [detailRetry, setDetailRetry] = useState(0);
  const error = detailError ?? directory.error;
  const [currentId, setCurrentId] = useState<number | null>(() => {
    if (routeChannelId == null) return null;
    const parsed = Number(routeChannelId);
    const known = useLiveStore.getState().channels.find((item) => item.id === parsed
      && (item.allowed_group_ids ?? []).some((id) => String(id) === String(groupId)));
    return known?.id ?? null;
  });
  const [showCreate, setShowCreate] = useState(false);
  const [creatingNew, setCreatingNew] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  useEffect(() => {
    if (!routeChannelId) return;
    let cancelled = false;
    setDetailError(null);
    void liveApi.getLiveChannel(Number(routeChannelId)).then((item) => {
      if (cancelled) return;
      if (!(item.allowed_group_ids ?? []).some((id) => String(id) === String(groupId))) {
        setDetailError("该直播间不在本群可见范围内");
        return;
      }
      useLiveStore.getState().upsertChannel(item);
      setCurrentId(item.id);
    }).catch((reason: unknown) => {
      if (!cancelled) setDetailError(reason instanceof Error ? reason.message : "加载直播间失败");
    });
    return () => { cancelled = true; };
  }, [groupId, routeChannelId, detailRetry]);

  useEffect(() => {
    if (currentId == null && !routeChannelId && channels.length > 0) {
      setCurrentId(channels[0].id);
    }
    const index = channels.findIndex((item) => item.id === currentId);
    if (index >= 0 && index >= channels.length - 3 && !directory.error) void directory.loadMore();
  }, [channels, currentId, routeChannelId, directory.loadMore, directory.error]);

  // 侧栏点击直播间 → URL 带 liveChannelId：仅在路由参数变化时同步一次，
  // 不覆盖后续上下滑/侧栏切换产生的 currentId。ref 初始为当前 routeChannelId，
  // 首屏由 useState 初始值直接命中，无需再同步。
  const lastRouteChannelIdRef = useRef(routeChannelId);
  useEffect(() => {
    if (routeChannelId == null || lastRouteChannelIdRef.current === routeChannelId) return;
    const target = channels.find((item) => String(item.id) === String(routeChannelId));
    if (target) {
      lastRouteChannelIdRef.current = routeChannelId;
      setCurrentId(target.id);
    }
  }, [routeChannelId, channels]);

  const goTo = useCallback(
    (id: number) => {
      if (id === currentId) return;
      setCurrentId(id);
    },
    [currentId],
  );

  const handleLiveStarted = useCallback(
    (started: LiveChannelDescriptor) => {
      setShowCreate(false);
      navigate(`/live/start/${started.id}`);
    },
    [navigate],
  );

  const handleCreateNewLive = useCallback(async () => {
    setCreatingNew(true);
    setCreateError(null);
    try {
      // 群内开播：本群自动勾选（后端兜底落白名单），但不锁定——用户可在开播控制台取消本群。
      const created = await liveApi.createLiveChannel("新直播间", groupId);
      setShowCreate(false);
      navigate(`/live/start/${created.id}`);
    } catch (e) {
      setCreateError(e instanceof Error ? e.message : "创建直播间失败");
    } finally {
      setCreatingNew(false);
    }
  }, [groupId, navigate]);

  if (currentId == null && !error && ((loading && channels.length === 0) || routeChannelId != null)) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 160, width: "80%" }} />
      </div>
    );
  }

  if (error && (detailError || currentId == null)) {
    return (
      <div className="group-scene-placeholder" role="alert">
        <h3 className="placeholder-title">群内直播加载失败</h3>
        <p className="placeholder-desc">{error}</p>
        <button type="button" className="btn btn-ghost" onClick={() => { if (detailError) setDetailRetry((value) => value + 1); else void load(); }}>重试</button>
      </div>
    );
  }

  if (currentId == null) {
    return (
      <>
        <div className="group-scene-placeholder">
          <h3 className="placeholder-title">群内还没有直播</h3>
          <p className="placeholder-desc">发起本群的第一场直播吧</p>
          <div className="group-scene-placeholder-actions">
            <button
              type="button"
              className="btn btn-glow"
              onClick={() => {
                setCreateError(null);
                setShowCreate(true);
              }}
            >
              创建群内直播
            </button>
            <button type="button" className="btn btn-ghost" onClick={onExit}>
              返回聊天
            </button>
          </div>
        </div>
        {showCreate && (
          <CreateSheet title="群内开播" onClose={() => setShowCreate(false)}>
            <LiveStartSheet
              onStart={handleLiveStarted}
              onCreateNew={() => void handleCreateNewLive()}
              creatingNew={creatingNew}
              createError={createError}
            />
          </CreateSheet>
        )}
      </>
    );
  }

  return (
    <>
    <LiveRoomBody
      directory={directory}
      channelId={currentId}
      channel={channel}
      isNarrow={isNarrow}
      channels={channels}
      onSelect={goTo}
      onBack={onExit}
      inputEntered // 群内子界面无底栏下滑动画，输入框直接显示
      activityRoute={`/group/${groupId}/live`}
      onCreateNewChannel={() => {
        setCreateError(null);
        setShowCreate(true);
      }}
      hideRail
    />
  {showCreate && (
    <CreateSheet title="群内开播" onClose={() => setShowCreate(false)}>
      <LiveStartSheet
        onStart={handleLiveStarted}
        onCreateNew={() => void handleCreateNewLive()}
        creatingNew={creatingNew}
        createError={createError}
      />
    </CreateSheet>
  )}
    </>
  );
}
