/**
 * GroupVoice —— 群内语音子界面（F5，R-G8）。
 *
 * 该群语音房卡片列表（服务端 group_id + allowed_groups 过滤后游标分页）+ 点卡片进房（上麦/静音/离开）。
 * 房内打字发到该群会话（复用群会话方案，开发文档 §1.9）。无语音房 → 空态 + 发起引导。
 * 进房与切房由 VoiceRoomBody 独立编排标题、成员和聊天面板，内部输入不叠加入场。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../../api/elysia";
import * as voiceApi from "../../api/voice";
import type { ElysiaProfile } from "../../api/types";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { VoiceChannelList } from "../../components/voice/VoiceChannelList";
import { VoiceRoomBody } from "../../components/voice/VoiceRoomBody";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceChannel } from "../../hooks/useVoiceChannel";
import { useShellStore } from "../../stores/shell";
import { useVoiceStore } from "../../stores/voice";
import { useDirectoryPage } from "../../hooks/useDirectoryPage";
import { useListEntryMotion } from "../../hooks/useListEntryMotion";
import { DirectoryLoadMore } from "../../components/DirectoryLoadMore";

export function GroupVoice({
  groupId,
  routeChannelId,
  onExit,
}: {
  groupId: string;
  routeChannelId?: string;
  onExit: () => void;
}) {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const channels = useVoiceStore((s) => s.channels);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const directory = useDirectoryPage("voice", { groupId }, !routeChannelId);
  const groupChannels = directory.items;
  const loaded = !directory.loading || groupChannels.length > 0;
  const [error, setError] = useState<string | null>(null);
  const [detailRetry, setDetailRetry] = useState(0);
  const [profileError, setProfileError] = useState<string | null>(null);
  // 删除语音房确认弹窗
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);
  const hubRef = useRef<HTMLDivElement>(null);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  useListEntryMotion(hubRef, ".voice-channel-card-wrap", false, replayNonce);
  // 记录上次已触发 join 的路由频道 id：仅当 routeChannelId 变化时才 join，
  // 避免 leave 清空 currentChannelId 后、navigate 尚未更新路由的窗口里被 effect 误判
  // 为"需要重新加入"而把用户拉回房间（"离开不了"）。
  const lastJoinRouteRef = useRef<string | null>(null);

  const {
    currentChannelId,
    livekit,
    joining,
    error: joinError,
    join,
    leave,
    toggleMic,
    setMemberVolume,
    setMemberLocallyMuted,
    setLocalVolume,
    resetLocal,
  } = useVoiceChannel(routeChannelId ?? null);

  const refresh = directory.refresh;
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

  // 上拉刷新仅当滚动容器（.group-voice）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  useEffect(() => {
    if (!routeChannelId || channels.some((item) => item.id === routeChannelId
      && (item.allowed_group_ids ?? []).some((id) => String(id) === String(groupId)))) return;
    let cancelled = false;
    setError(null);
    void voiceApi.getVoiceChannel(routeChannelId).then((item) => {
      if (cancelled) return;
      if (!(item.allowed_group_ids ?? []).some((id) => String(id) === String(groupId))) {
        setError("该语音房不在本群可见范围内");
        return;
      }
      useVoiceStore.getState().upsertChannel(item);
    }).catch((reason: unknown) => {
      if (!cancelled) setError(reason instanceof Error ? reason.message : "加载语音房失败");
    });
    return () => { cancelled = true; };
  }, [routeChannelId, groupId, channels, detailRetry]);

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
    (channelId: string) => {
      navigate(`/group/${groupId}/voice/${encodeURIComponent(channelId)}`);
    },
    [groupId, navigate],
  );

  // 只在当前群且 URL 指向当前频道时渲染房内界面；/group/:id/voice 是列表。
  // 群可见性由 allowed_groups 白名单决定（含本群即属本群频道）。
  const currentChannel = routeChannelId
    ? channels.find(
        (c) =>
          c.id === routeChannelId &&
          (c.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
      ) ?? null
    : null;
  useEffect(() => {
    if (!routeChannelId) {
      lastJoinRouteRef.current = null;
      return;
    }
    if (!currentChannel || lastJoinRouteRef.current === routeChannelId) return;
    lastJoinRouteRef.current = routeChannelId;
    void join(routeChannelId, { joinMuted: true });
  }, [join, routeChannelId, currentChannel]);
  // 顶部返回只离开房间界面，保留语音连接与全局浮层；面板里的“离开频道”才真正退出。
  const handleBack = useCallback(() => {
    navigate(`/group/${groupId}/voice`);
  }, [groupId, navigate]);
  // 房主可直接退出（不再要求先转让房主）。
  const handleLeave = useCallback(async () => {
    try {
      await leave();
      navigate(`/group/${groupId}/voice`);
    } catch (error) {
      window.alert(error instanceof Error ? error.message : "离开语音房失败");
    }
  }, [groupId, leave, navigate]);

  if (currentChannel) {
    return (
      <>
        <VoiceRoomBody
          channelId={currentChannel.id}
          ownerId={currentChannel.owner_id}
          channelName={currentChannel.name}
          channel={currentChannel}
          livekit={joining ? "connecting" : joinError ? "failed" : currentChannelId === currentChannel.id ? livekit : "idle"}
          connectionError={joinError ?? error}
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
          onDeleteChannel={() => { setError(null); setConfirmDeleteOpen(true); }}
          inputEntered // 群内子界面无底栏下滑动画
        />
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
                  navigate(`/group/${groupId}/voice`);
                })
                .catch((e) => setError(e instanceof Error ? e.message : "删除语音房失败"));
            }}
            onClose={() => setConfirmDeleteOpen(false)}
          />
        )}
      </>
    );
  }

  if (routeChannelId) return <div className="group-scene-placeholder" role={error ? "alert" : "status"}>
    {error ? <><p>{error}</p><button type="button" className="btn btn-ghost" onClick={() => setDetailRetry((value) => value + 1)}>重试</button></>
      : <><div className="skeleton" style={{ height: 96, width: "80%" }} /><span>正在加载语音房…</span></>}
  </div>;

  return (
    <div className={`group-voice ${isNarrow ? "" : "is-wide"}`} ref={hubRef} onScroll={(event) => directory.onScroll(event.currentTarget)}>
      <div className="group-scene-head">
        <div className="group-scene-head-copy">
          <h3 className="group-scene-title">群内语音房</h3>
          <p className="group-scene-desc">选择一个房间加入，或点击右下角创建新的群内语音房</p>
        </div>
      </div>
      {profileError && <div className="chat-notice" role="alert">爱莉入口暂不可用：{profileError}</div>}
      {(error || directory.error) && groupChannels.length === 0 ? (
        <div className="group-scene-placeholder" role="alert">
          <p className="placeholder-desc">{error ?? directory.error}</p>
          <button type="button" className="btn btn-ghost" onClick={() => void refresh()}>重试</button>
        </div>
      ) : !loaded ? (
        <div className="group-voice-loading" aria-busy="true">
          <span className="skeleton" style={{ height: 64, width: "100%", borderRadius: 12 }} />
          <span className="skeleton" style={{ height: 64, width: "100%", borderRadius: 12 }} />
          <span className="skeleton" style={{ height: 64, width: "100%", borderRadius: 12 }} />
          <span className="home-load-text">正在加载语音房…</span>
        </div>
      ) : groupChannels.length === 0 ? (
        <div className="group-scene-placeholder">
          <h3 className="placeholder-title">群内还没有语音房</h3>
          <p className="placeholder-desc">建一个群内语音房，一起连麦</p>
          <div className="group-voice-empty-actions">
            <button type="button" className="btn btn-ghost" onClick={onExit}>
              返回聊天
            </button>
          </div>
        </div>
      ) : (
        <PullToRefresh isAtTop={isAtTop} onRefresh={refreshWithReplay}>
          <VoiceChannelList
            channels={groupChannels}
            currentChannelId={currentChannelId}
            joining={joining}
            onJoin={handleJoin}
          />
          <DirectoryLoadMore {...directory} />
        </PullToRefresh>
      )}
    </div>
  );
}
