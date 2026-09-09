/**
 * VoiceHubPage —— 一级语音 tab 聚合视图（路由 /voice，F5 改造 VoicePage）。
 *
 * 语音房卡片（聚合 + 来源标识公开/好友/群名，R-V1）；进房 = 底栏下滑走 + 输入框滑入
 * （useEnterRoomAnimation + shell store，与直播同向、与进群相反）；房内打字发到
 * 群会话（仅群语音房，开发文档 §1.9）；返回键回卡片列表（底栏复位）。
 * 建语音房走右下 FAB（CreateFab handler=voice，F5 接线）。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
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
import { useVoiceStore } from "../stores/voice";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { useSocialPage } from "../hooks/useSocialPage";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { IconMic } from "../components/icons";
import { useAuthStore } from "../stores/auth";
import { voiceWS } from "../ws/voice";

type VoiceFilter = "all" | "public" | "friends" | "occupied" | "mine";
const FILTERS: ReadonlyArray<{ key: VoiceFilter; label: string }> = [
  { key: "all", label: "全部" },
  { key: "public", label: "公开" },
  { key: "friends", label: "好友" },
  { key: "occupied", label: "有人" },
  { key: "mine", label: "我的" },
];

export function VoiceHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { channelId: routeChannelId } = useParams<{ channelId?: string }>();
  // 仅在房内路由启动输入框滑入；离房复位，避免大厅预挂载使下次动画失效。
  const { inputEntered } = useEnterRoomAnimation(routeChannelId != null);
  const channels = useVoiceStore((s) => s.channels);
  // 分类选项卡：URL ?type= 驱动（与收藏/搜索一致），各 tab 独立滚动位置
  const selectionId = useId();
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const scope = `voice-hub:${filter}`;
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  // filter 进 directory key：每个 tab 独立游标/加载（切 tab 自动拉取该 tab 第一页）
  const directory = useDirectoryPage("voice", { filter }, !routeChannelId);
  const channelsLoading = directory.loading;
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [detailRetry, setDetailRetry] = useState(0);
  const [profileError, setProfileError] = useState<string | null>(null);
  // 删除语音房确认弹窗
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);
  const hubRef = useRef<HTMLDivElement>(null);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  // 好友 tab：作者是好友（friendIds 集合），不是 visibility=friends 才显示
  const friendsPage = useSocialPage("friends", {}, !routeChannelId);
  const friendIds = useMemo(() => new Set(friendsPage.items.map((f) => f.user.id)), [friendsPage.items]);
  // 过滤全部前端实现（用户自建房间量级小，分页加载后过滤够用）；排序保持 directory 原排序
  const visibleChannels = useMemo(() => {
    if (filter === "all") return directory.items;
    return directory.items.filter((channel) => {
      switch (filter) {
        case "public": return channel.visibility === "public";
        case "friends": return friendIds.has(channel.owner_id);
        case "occupied": return channel.member_count > 0;
        case "mine": return channel.owner_id === currentUserId;
        default: return true;
      }
    });
  }, [directory.items, filter, currentUserId, friendIds]);
  const { restoring } = useScrollRestore(scope, hubRef, { ready: !channelsLoading || directory.items.length > 0 });
  useListEntryMotion(hubRef, ".voice-channel-card-wrap", restoring, replayNonce);
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
    resetLocal,
  } = useVoiceChannel(routeChannelId ?? null);

  const refresh = directory.refresh;
  const loadChannels = directory.refresh;
  // 刷新键/下拉刷新共用：刷新完成后重播已入场卡片浮入
  const refreshWithReplay = useCallback(async () => {
    await refresh();
    setReplayNonce((n) => n + 1);
  }, [refresh]);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refreshWithReplay);
    return () => {
      if (useShellStore.getState().refreshCallback === refreshWithReplay) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refreshWithReplay]);

  // 上拉刷新仅当滚动容器（.directory-content）已在顶部时响应
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
    setListError(null);
    void voiceApi.getVoiceChannel(routeChannelId)
      .then((channel) => {
        if (!cancelled) useVoiceStore.getState().upsertChannel(channel);
      })
      .catch((reason: unknown) => {
        if (!cancelled) setListError(reason instanceof Error ? reason.message : "加载语音房失败");
      });
    return () => {
      cancelled = true;
    };
  }, [channels, routeChannelId, detailRetry]);

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
            livekit={joining ? "connecting" : joinError ? "failed" : currentChannelId === currentChannel.id ? livekit : "idle"}
            connectionError={joinError ?? listError}
            wsConnection={wsConnection}
            elysiaProfile={elysiaProfile}
            groupId={currentChannel.group}
            onToggleMic={() => void toggleMic()}
            onLeave={() => void handleLeave()}
            onRejoin={() => void join(currentChannel.id, { joinMuted: true, force: true })}
            onVolumeChange={setMemberVolume}
            onLocalVolumeChange={setLocalVolume}
            onToggleMemberMuted={(userId) => {
              const m = useVoiceStore.getState().members[userId];
              if (m) setMemberLocallyMuted(userId, !m.locallyMuted);
            }}
            onBack={handleBack}
            onDeleteChannel={() => { setListError(null); setConfirmDeleteOpen(true); }}
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

  if (routeChannelId) return <div className="voice-hub"><div className="home-state" role={listError ? "alert" : "status"}>
    {listError ? <><p>{listError}</p><button type="button" className="btn btn-ghost" onClick={() => setDetailRetry((value) => value + 1)}>重试</button></>
      : <><div className="skeleton" style={{ height: 96 }} /><span>正在加载语音房…</span></>}
  </div></div>;

  return (
    <div className="voice-hub directory-page">
      <div className="directory-body">
        <DirectoryFilters id={selectionId} label="语音分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="voice-filters" buttonClassName="voice-filter"
          onChange={(next) => {
            saveScrollPosition(scope, hubRef.current);
            setParams(next === "all" ? {} : { type: next }, { replace: true });
          }}
          decor={<IconMic width={64} height={64} className="directory-filter-decor voice-filter-decor" role="presentation" aria-hidden="true" />}
          header={<div className="directory-filter-header">
            <span className="directory-filter-kicker">Voice</span>
            <span className="directory-filter-title">语音房间</span>
            {directory.total > 0 && <span className="directory-filter-stats">
              {directory.totalMemberCount != null
                ? `${directory.total} 房间在线 · ${directory.totalMemberCount} 人在聊`
                : `${directory.total} 房间在线`}
            </span>}
          </div>} />
        <div key={scope} className="directory-content voice-content" ref={hubRef}
          id={`${selectionId}-panel`} role="tabpanel" aria-labelledby={`${selectionId}-${filter}`} tabIndex={0}
          onScroll={(event) => directory.onScroll(event.currentTarget)}>
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
          {channelsLoading && directory.items.length === 0 ? (
            <div className="conv-loading">
              <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
              <div className="skeleton" style={{ height: 64 }} />
            </div>
          ) : directory.error && directory.items.length === 0 ? <DirectoryLoadMore {...directory} /> : (
            <PullToRefresh isAtTop={isAtTop} onRefresh={refreshWithReplay}>
              {visibleChannels.length === 0 && filter !== "all" ? (
                <div className="home-state">
                  <h3 className="placeholder-title">这个分类还没有语音房</h3>
                  <p className="placeholder-desc">换个分类看看</p>
                </div>
              ) : (
                <VoiceChannelList
                  channels={visibleChannels}
                  currentChannelId={currentChannelId}
                  joining={joining}
                  onJoin={handleJoin}
                />
              )}
              <DirectoryLoadMore {...directory} />
            </PullToRefresh>
          )}
        </div>
      </div>
    </div>
  );
}
