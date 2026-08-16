/**
 * VoiceHubPage —— 一级语音 tab 聚合视图（路由 /voice，F5 改造 VoicePage）。
 *
 * 语音房卡片（聚合 + 来源标识公开/好友/群名，R-V1）；进房 = 底栏下滑走 + 输入框滑入
 * （useEnterRoomAnimation + shell store，与直播同向、与进群相反）；房内打字发到
 * 群会话（仅群语音房，开发文档 §1.9）；返回键回卡片列表（底栏复位）。
 * 建语音房走右下 FAB（CreateFab handler=voice，F5 接线）。
 */
import { useCallback, useEffect, useState } from "react";
import { getElysiaProfile } from "../api/elysia";
import * as voiceApi from "../api/voice";
import type { ElysiaProfile } from "../api/types";
import { VoiceRoomBody } from "../components/voice/VoiceRoomBody";
import { VoiceChannelList } from "../components/voice/VoiceChannelList";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEnterRoomAnimation } from "../hooks/useEnterRoomAnimation";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useShellStore } from "../stores/shell";
import { useVoiceChannel } from "../hooks/useVoiceChannel";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";

export function VoiceHubPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { inputEntered } = useEnterRoomAnimation();
  const channels = useVoiceStore((s) => s.channels);
  const channelsLoading = useVoiceStore((s) => s.channelsLoading);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [listError, setListError] = useState<string | null>(null);

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

  // 进房/退房：底栏下滑走（R-V2，与直播同向）
  useEffect(() => {
    useShellStore.getState().setBottomTabsLeaving(currentChannelId != null);
  }, [currentChannelId]);

  // 频道列表
  useEffect(() => {
    let cancelled = false;
    const store = useVoiceStore.getState();
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
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  const handleJoin = useCallback((channelId: string) => void join(channelId, { joinMuted: true }), [join]);
  const currentChannel = channels.find((c) => c.id === currentChannelId) ?? null;
  const notice = joinError ?? listError;

  // 进房态（两种形态都渲染语音房面板 + 房内打字）
  if (currentChannel) {
    return (
      <VoiceRoomBody
        channelName={currentChannel.name}
        livekit={livekit}
        wsConnection={wsConnection}
        elysiaProfile={elysiaProfile}
        groupId={currentChannel.group}
        onToggleMic={() => void toggleMic()}
        onLeave={() => void leave()}
        onRejoin={() => void rejoin()}
        onVolumeChange={setMemberVolume}
        onLocalVolumeChange={setLocalVolume}
        onToggleMemberMuted={(userId) => {
          const m = useVoiceStore.getState().members[userId];
          if (m) setMemberLocallyMuted(userId, !m.locallyMuted);
        }}
        onBack={() => void leave()}
        inputEntered={inputEntered}
      />
    );
  }

  return (
    <div className="voice-hub">
      {isNarrow && <NarrowTopBar />}
      {notice && (
        <div
          className="chat-notice"
          role="alert"
          onClick={() => {
            clearError();
            setListError(null);
          }}
        >
          {notice}（点击关闭）
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
