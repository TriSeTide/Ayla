/**
 * GroupVoice —— 群内语音子界面（F5，R-G8）。
 *
 * 该群语音房卡片列表（filter group === groupId）+ 点卡片进房（上麦/静音/离开）。
 * 房内打字发到该群会话（复用群会话方案，开发文档 §1.9）。无语音房 → 空态 + 发起引导。
 * 群内子界面（底栏已在顶部，无独立进房动画，输入框直接显示）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../../api/elysia";
import * as voiceApi from "../../api/voice";
import type { ElysiaProfile } from "../../api/types";
import { VoiceChannelList } from "../../components/voice/VoiceChannelList";
import { VoiceRoomBody } from "../../components/voice/VoiceRoomBody";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceChannel } from "../../hooks/useVoiceChannel";
import { useShellStore } from "../../stores/shell";
import { useVoiceStore } from "../../stores/voice";

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
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制语音列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);
  // 记录上次已触发 join 的路由频道 id：仅当 routeChannelId 变化时才 join，
  // 避免 leave 清空 currentChannelId 后、navigate 尚未更新路由的窗口里被 effect 误判
  // 为"需要重新加入"而把用户拉回房间（"离开不了"）。
  const lastJoinRouteRef = useRef<string | null>(null);

  const {
    currentChannelId,
    livekit,
    joining,
    join,
    leave,
    toggleMic,
    setMemberVolume,
    setMemberLocallyMuted,
    setLocalVolume,
    rejoin,
  } = useVoiceChannel();

  // 全量可见频道写入全局 store（后端 visible_queryset 已含本用户所有群的
  // group/allowed_groups 频道），再按 groupId 前端投影当前群；
  // 不能用 scope=group:<id> 直接覆盖 store，否则跨群切换时全局列表被单群数据污染。
  const groupChannels = channels.filter((c) =>
    (c.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
  );

  // 上拉刷新/刷新键共用：强制重拉语音房列表
  const refresh = useCallback(async () => {
    setError(null);
    try {
      const list = await voiceApi.listVoiceChannels();
      useVoiceStore.getState().setChannels(list);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : "加载群内语音房失败");
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

  // 上拉刷新仅当滚动容器（.group-voice）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  useEffect(() => {
    let cancelled = false;
    const store = useVoiceStore.getState();
    // 复用全局 store 缓存（同 GroupLive 模式）：已有数据且未过期则不重拉，
    // 避免每次切到群内语音都强制请求导致"空白加载"。仅在全量列表缺失/过期时拉取。
    if (store.channels.length > 0 && store.lastFetched != null && Date.now() - store.lastFetched <= 60_000) {
      setLoaded(true);
      return () => {
        cancelled = true;
      };
    }
    setLoaded(false);
    setError(null);
    voiceApi
      .listVoiceChannels()
      .then((list) => {
        if (!cancelled) useVoiceStore.getState().setChannels(list);
      })
      .catch((e) => {
        if (!cancelled) setError(e instanceof Error ? e.message : "加载群内语音房失败");
      })
      .finally(() => {
        if (!cancelled) setLoaded(true);
      });
    return () => {
      cancelled = true;
    };
  }, [groupId]);

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

  useEffect(() => {
    if (!routeChannelId) {
      lastJoinRouteRef.current = null;
      return;
    }
    if (lastJoinRouteRef.current === routeChannelId) return;
    lastJoinRouteRef.current = routeChannelId;
    void join(routeChannelId, { joinMuted: true });
  }, [join, routeChannelId]);

  // 只在当前群且 URL 指向当前频道时渲染房内界面；/group/:id/voice 是列表。
  // 群可见性由 allowed_groups 白名单决定（含本群即属本群频道）。
  const currentChannel = routeChannelId
    ? channels.find(
        (c) =>
          c.id === routeChannelId &&
          (c.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
      ) ?? null
    : null;
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
        onDeleteChannel={() => {
          if (!window.confirm("确定删除语音房？")) return;
          void voiceApi.deleteVoiceChannel(currentChannel.id).then(() => navigate(`/group/${groupId}/voice`)).catch((e) => setError(e instanceof Error ? e.message : "删除语音房失败"));
        }}
        inputEntered // 群内子界面无底栏下滑动画
      />
    );
  }

  return (
    <div className={`group-voice ${isNarrow ? "" : "is-wide"}`} ref={hubRef}>
      <div className="group-scene-head">
        <div className="group-scene-head-copy">
          <h3 className="group-scene-title">群内语音房</h3>
          <p className="group-scene-desc">选择一个房间加入，或点击右下角创建新的群内语音房</p>
        </div>
      </div>
      {profileError && <div className="chat-notice" role="alert">爱莉入口暂不可用：{profileError}</div>}
      {error ? (
        <div className="group-scene-placeholder" role="alert">
          <p className="placeholder-desc">{error}</p>
          <button type="button" className="btn btn-ghost" onClick={() => {
            setError(null);
            setLoaded(false);
            void voiceApi.listVoiceChannels()
              .then((list) => useVoiceStore.getState().setChannels(list))
              .catch((e) => setError(e instanceof Error ? e.message : "加载群内语音房失败"))
              .finally(() => setLoaded(true));
          }}>重试</button>
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
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          <VoiceChannelList
            key={revealNonce}
            channels={groupChannels}
            currentChannelId={currentChannelId}
            joining={joining}
            onJoin={handleJoin}
            revealItems={loaded}
          />
        </PullToRefresh>
      )}
    </div>
  );
}
