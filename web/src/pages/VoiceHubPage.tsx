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
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";
import { VoiceChannelList } from "../components/voice/VoiceChannelList";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useShellStore } from "../stores/shell";
import { useAuthStore } from "../stores/auth";
import { useVoiceChannel } from "../hooks/useVoiceChannel";
import { useVoiceStore, isVoiceStale } from "../stores/voice";
import { voiceWS } from "../ws/voice";

export function VoiceHubPage() {
  const navigate = useNavigate();
  const { channelId: routeChannelId } = useParams<{ channelId?: string }>();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  // 仅在房内路由启动输入框滑入；离房复位，避免大厅预挂载使下次动画失效。
  const { inputEntered } = useEnterRoomAnimation(routeChannelId != null);
  const channels = useVoiceStore((s) => s.channels);
  const channelsLoading = useVoiceStore((s) => s.channelsLoading);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const joiningRouteRef = useRef<string | null>(null);

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

  // 进房/退房：底栏下滑走（R-V2，与直播同向）
  useEffect(() => {
    // 路由是壳层底栏是否让位的唯一事实：即使连接保留在全局浮层，返回 /voice 或主页时也必须复位。
    useShellStore.getState().setBottomTabsLeaving(routeChannelId != null && currentChannelId != null);
    return () => {
      useShellStore.getState().setBottomTabsLeaving(false);
    };
  }, [currentChannelId, routeChannelId]);

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
  useEffect(() => {
    if (
      routeChannelId &&
      currentChannelId !== routeChannelId &&
      !joining &&
      joiningRouteRef.current !== routeChannelId
    ) {
      joiningRouteRef.current = routeChannelId;
      void join(routeChannelId, { joinMuted: true });
    }
  }, [currentChannelId, joining, join, routeChannelId]);

  const currentChannel = routeChannelId
    ? channels.find((c) => c.id === routeChannelId) ?? null
    : null;
  const currentUser = useAuthStore((s) => s.currentUser);
  // 顶部返回只离开房间界面，保留语音连接与全局浮层；面板里的“离开频道”才真正退出。
  const handleBack = useCallback(() => {
    navigate("/voice");
  }, [navigate]);
  const handleLeave = useCallback(async () => {
    // 房主必须先转让房主才能离开（后端 403 强校验，前端先拦截避免状态混乱）
    if (currentChannel && currentChannel.owner_id === currentUser?.id) {
      window.confirm("你是房主，退出前应先转让房主");
      return;
    }
    try {
      await leave();
      navigate("/voice");
    } catch (error) {
      window.alert(error instanceof Error ? error.message : "离开语音房失败");
    }
  }, [currentChannel, currentUser, leave, navigate]);
  const notice = joinError ?? listError;

  // 进房态（两种形态都渲染语音房面板 + 房内打字）
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
          void voiceApi.deleteVoiceChannel(currentChannel.id).then(() => navigate("/voice")).catch((error) => setListError(error instanceof Error ? error.message : "删除语音房失败"));
        }}
        inputEntered={inputEntered}
      />
    );
  }

  return (
    <div className="voice-hub">
      {isNarrow && <NarrowTopBar />}
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
        <VoiceChannelList
          channels={channels}
          currentChannelId={currentChannelId}
          joining={joining}
          onJoin={handleJoin}
        />
      )}
    </div>
  );
}
