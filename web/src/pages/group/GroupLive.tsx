/**
 * GroupLive —— 群内直播子界面（F4，R-G7）。
 *
 * 直接进入该群第一个直播间（无卡片列表）；上下滑切换范围 = **仅该群**（与一级直播
 * tab 的"全部可见"不同，R-G7/R-L3 明确区分）。无直播 → 空态 + 发起引导。
 *
 * 群内直播是 GroupPage 的 live 子界面（底栏已在顶部，无"底栏下滑走"进房动画，
 * 输入框直接显示）；宽屏同 ChannelSidebar 内容区。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as liveApi from "../../api/live";
import type { LiveChannelDescriptor } from "../../api/types";
import { CreateSheet } from "../../layout/CreateSheet";
import { LiveStartSheet } from "../../components/live/LiveStartSheet";
import { LiveRoomBody } from "../../components/live/LiveRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useLiveStore } from "../../stores/live";

export function GroupLive({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const channel = useLiveStore((s) => s.current.channel);
  const allChannels = useLiveStore((s) => s.channels);
  const channels = allChannels.filter((item) =>
    String(item.group) === String(groupId)
    || (item.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
  );
  const [currentId, setCurrentId] = useState<number | null>(null);
  const loading = useLiveStore((s) => s.channelsLoading);
  const error = useLiveStore((s) => s.error);
  const [showCreate, setShowCreate] = useState(false);
  const [creatingNew, setCreatingNew] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  const load = useCallback(() => {
    // 全量可见列表写入全局 store（后端 visible_queryset 已含本用户所有群的
    // group/allowed_groups 频道），再在下方按 groupId 前端投影当前群；
    // 不能用 scope=group:<id> 直接覆盖 store，否则跨群切换时全局列表被单群数据污染。
    const store = useLiveStore.getState();
    store.setChannelsLoading(true);
    store.setError(null);
    liveApi
      .listLiveChannels()
      .then((list) => store.setChannels(list))
      .catch((e) => {
        store.setChannelsLoading(false);
        store.setError(e instanceof Error ? e.message : "加载群内直播失败");
      });
  }, [groupId]);

  useEffect(() => {
    const store = useLiveStore.getState();
    if (store.channels.length === 0 || store.lastFetched == null || Date.now() - store.lastFetched > 60_000) {
      load();
    }
  }, [load]);

  useEffect(() => {
    if (channels.length === 0) {
      setCurrentId(null);
      return;
    }
    if (currentId == null || !channels.some((item) => item.id === currentId)) {
      setCurrentId(channels[0].id);
    }
  }, [channels, currentId]);

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
      const created = await liveApi.createLiveChannel("新直播间", groupId);
      setShowCreate(false);
      navigate(`/live/start/${created.id}`);
    } catch (e) {
      setCreateError(e instanceof Error ? e.message : "创建直播间失败");
    } finally {
      setCreatingNew(false);
    }
  }, [groupId, navigate]);

  if (loading) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 160, width: "80%" }} />
      </div>
    );
  }

  if (error) {
    return (
      <div className="group-scene-placeholder" role="alert">
        <h3 className="placeholder-title">群内直播加载失败</h3>
        <p className="placeholder-desc">{error}</p>
        <button type="button" className="btn btn-ghost" onClick={load}>重试</button>
      </div>
    );
  }

  if (channels.length === 0 || currentId == null) {
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
      channelId={currentId}
      channel={channel}
      isNarrow={isNarrow}
      channels={channels}
      onSelect={goTo}
      onBack={onExit}
      inputEntered // 群内子界面无底栏下滑动画，输入框直接显示
      onCreateNewChannel={() => {
        setCreateError(null);
        setShowCreate(true);
      }}
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
