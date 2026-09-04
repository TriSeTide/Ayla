/**
 * VoiceHubPage —— 一级语音 tab 聚合视图（路由 /voice，F5 改造 VoicePage）。
 *
 * 语音房卡片（聚合 + 来源标识公开/好友/群名，R-V1）；进房 = 底栏下滑走 + 输入框滑入
 * （useEnterRoomAnimation + shell store，与直播同向、与进群相反）；房内打字发到
 * 群会话（仅群语音房，开发文档 §1.9）；返回键回卡片列表（底栏复位）。
 * 建语音房走右下 FAB（CreateFab handler=voice，F5 接线）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getElysiaProfile } from "../api/elysia";
import * as voiceApi from "../api/voice";
import type { ElysiaProfile } from "../api/types";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";
import { VoiceChannelList } from "../components/voice/VoiceChannelList";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { useShellStore } from "../stores/shell";
import { useVoiceChannel } from "../hooks/useVoiceChannel";
import { useVoiceStore, isVoiceStale } from "../stores/voice";
import { voiceWS } from "../ws/voice";

export function VoiceHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { channelId: routeChannelId } = useParams<{ channelId?: string }>();
  // 仅在房内路由启动输入框滑入；离房复位，避免大厅预挂载使下次动画失效。
  const { inputEntered } = useEnterRoomAnimation(routeChannelId != null);
  const channels = useVoiceStore((s) => s.channels);
  const channelsLoading = useVoiceStore((s) => s.channelsLoading);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  // 删除语音房确认弹窗
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制语音列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);
  // 记录上次已触发 join 的路由频道 id：仅当 routeChannelId 变化时才 join，
  // 避免 leave 清空 currentChannelId 后、navigate 尚未更新路由的窗口里被 effect 误判
  // 为"需要重新加入"而把用户拉回房间（"离开不了"）；离房时清空以支持再次进入。
  const lastJoinRouteRef = useRef<string | null>(null);

  const {
    currentChannelId,
    livekit,
    joining,
    error: joinError,
    clearError,
    join,
    leave,
    toggleMic,
    setMemberVolume,
    setMemberLocallyMuted,
    setLocalVolume,
    rejoin,
    resetLocal,
  } = useVoiceChannel();

  // ✅ 统一的频道列表加载函数
  const loadChannels = useCallback(() => {
    const store = useVoiceStore.getState();
    store.setChannelsLoading(true);
    setListError(null);
    voiceApi
      .listVoiceChannels()
      .then((list) => store.setChannels(list))
      .catch((e) => {
        store.setChannelsLoading(false);
        setListError(e instanceof Error ? e.message : "加载频道失败");
      });
  }, []);

  // 上拉刷新/刷新键共用：强制重拉语音房列表（不设 loading 以免骨架闪现）
  const refresh = useCallback(async () => {
    setListError(null);
    try {
      const list = await voiceApi.listVoiceChannels();
      useVoiceStore.getState().setChannels(list);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      setListError(e instanceof Error ? e.message : "加载频道失败");
    }
  }, []);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 上拉刷新仅当滚动容器（.voice-hub）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  // 进房/退房：底栏下滑走（R-V2，与直播同向）。路由是壳层底栏是否让位的唯一事实：
  // 进入 /voice/:id 立即让底栏下滑走（200ms ease-in），输入框随后延迟滑入（useEnterRoomAnimation），
  // 与直播间/帖子详情同序；返回 /voice 或主页时复位。即使连接保留在全局浮层也必须复位。
  // 仅房内注册 effect（对齐 LiveRoomPage/PostDetailPage「房间页才驱动」）：大厅与房间共用
  // 本组件，页面转场期间新旧两实例并存约 150ms（AnimatePresence 退出窗口），若大厅实例
  // 也注册 cleanup，会在新房间实例置 true 后被其卸载 cleanup 覆盖回 false，底栏滑出又被拉回。
  useEffect(() => {
    if (routeChannelId == null) return;
    useShellStore.getState().setBottomTabsLeaving(true);
    return () => {
      useShellStore.getState().setBottomTabsLeaving(false);
    };
  }, [routeChannelId]);

  // 频道列表：空或过期时加载
  useEffect(() => {
    let cancelled = false;
    const store = useVoiceStore.getState();
    if (store.channels.length > 0 && !isVoiceStale()) return;
    store.setChannelsLoading(true);
    voiceApi
      .listVoiceChannels()
      .then((list) => {
        if (!cancelled) store.setChannels(list);
      })
      .catch((e) => {
        if (!cancelled) {
          store.setChannelsLoading(false);
          setListError(e instanceof Error ? e.message : "加载频道失败");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Voice WS 单例
  useEffect(() => {
    voiceWS.connect();
  }, []);

  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaProfile(p.enabled ? p : null);
      })
      .catch((e) => {
        if (!cancelled) setProfileError(e instanceof Error ? e.message : "加载爱莉资料失败");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const handleJoin = useCallback(
    async (channelId: string) => {
      navigate(`/voice/${encodeURIComponent(channelId)}`);
    },
    [navigate],
  );

  // 直接进入 /voice/:id 时，即使大厅列表还没返回，也先拉详情，确保房内界面能渲染。
  useEffect(() => {
    if (!routeChannelId || channels.some((channel) => channel.id === routeChannelId)) return;
    let cancelled = false;
    void voiceApi.getVoiceChannel(routeChannelId)
      .then((channel) => {
        if (!cancelled) useVoiceStore.getState().upsertChannel(channel);
      })
      .catch(() => {
        // 列表请求会继续负责错误展示；详情失败不覆盖已有状态。
      });
    return () => {
      cancelled = true;
    };
  }, [channels, routeChannelId]);

  // /voice/:channelId 是真实的语音房路由：进入该 URL 就加入对应房间，
  // 浮层点击因此不会只回列表，也支持刷新后按用户状态重新建立媒体连接。
  // 仅当 routeChannelId 变化时才 join（离房时清空标记以支持再次进入），避免 leave 后误判重进。
  useEffect(() => {
    if (!routeChannelId) {
      lastJoinRouteRef.current = null;
      return;
    }
    if (lastJoinRouteRef.current === routeChannelId) return;
    lastJoinRouteRef.current = routeChannelId;
    void join(routeChannelId, { joinMuted: true });
  }, [join, routeChannelId]);

  const currentChannel = routeChannelId
    ? channels.find((c) => c.id === routeChannelId) ?? null
    : null;
  // 顶部返回只离开房间界面，保留语音连接与全局浮层；面板里的“离开频道”才真正退出。
  const handleBack = useCallback(() => {
    navigate("/voice");
  }, [navigate]);
  // 房主可直接退出（不再要求先转让房主）。
  const handleLeave = useCallback(async () => {
    try {
      await leave();
      navigate("/voice");
    } catch (error) {
      window.alert(error instanceof Error ? error.message : "离开语音房失败");
    }
  }, [leave, navigate]);
  const notice = joinError ?? listError;

  // 进房态（两种形态都渲染语音房面板 + 房内打字）
  if (currentChannel) {
    return (
      <>
        <FullScreenSwipeBack onBack={handleBack} enabled={isNarrow}>
          <VoiceRoomBody
            channelId={currentChannel.id}
            ownerId={currentChannel.owner_id}
            channelName={currentChannel.name}
            channel={currentChannel}
            livekit={livekit}
            wsConnection={wsConnection}
            elysiaProfile={elysiaProfile}
            groupId={currentChannel.group}
            onToggleMic={() => void toggleMic()}
            onLeave={() => void handleLeave()}
            onRejoin={() => void rejoin()}
            onVolumeChange={setMemberVolume}
            onLocalVolumeChange={setLocalVolume}
            onToggleMemberMuted={(userId) => {
              const m = useVoiceStore.getState().members[userId];
              if (m) setMemberLocallyMuted(userId, !m.locallyMuted);
            }}
            onBack={handleBack}
            onDeleteChannel={() => setConfirmDeleteOpen(true)}
            inputEntered={inputEntered}
          />
        </FullScreenSwipeBack>
        {confirmDeleteOpen && (
          <ConfirmDialog
            title="删除语音房"
            message={`确定删除语音房「${currentChannel.name}」？此操作不可撤销，房间内所有人都会被移出。`}
            onConfirm={() => {
              setConfirmDeleteOpen(false);
              // 删除成功后本地即时收尾（断媒体/清活动态/移除列表项），不依赖 WS 广播时序；
              // 广播到达时 removeChannel/resetLocal 均幂等，其他在线客户端靠广播热更新。
              void voiceApi
                .deleteVoiceChannel(currentChannel.id)
                .then(() => {
                  resetLocal();
                  useVoiceStore.getState().removeChannel(currentChannel.id);
                  navigate("/voice");
                })
                .catch((error) =>
                  setListError(error instanceof Error ? error.message : "删除语音房失败"),
                );
            }}
            onClose={() => setConfirmDeleteOpen(false)}
          />
        )}
      </>
    );
  }

  return (
    <div className="voice-hub" ref={hubRef}>
      {profileError && <div className="chat-notice" role="alert">爱莉入口暂不可用：{profileError}</div>}
       {notice && (
        <div
          className="chat-notice"
          role="alert"
          onClick={() => {
            clearError();
            loadChannels();
          }}
        >
          {notice}（点击重试）
        </div>
      )}
      {channelsLoading && channels.length === 0 ? (
        <div className="conv-loading">
          <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 64 }} />
        </div>
      ) : (
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          <VoiceChannelList
            key={revealNonce}
            channels={channels}
            currentChannelId={currentChannelId}
            joining={joining}
            onJoin={handleJoin}
            revealItems={!channelsLoading}
          />
        </PullToRefresh>
      )}
    </div>
  );
}
