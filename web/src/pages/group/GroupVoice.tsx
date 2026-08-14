/**
 * GroupVoice —— 群内语音子界面（F5，R-G8）。
 *
 * 该群语音房卡片列表（filter group === groupId）+ 点卡片进房（上麦/静音/离开）。
 * 房内打字发到该群会话（复用群会话方案，开发文档 §1.9）。无语音房 → 空态 + 发起引导。
 * 群内子界面（底栏已在顶部，无独立进房动画，输入框直接显示）。
 */
import { useCallback, useEffect, useState } from "react";
import { getElysiaProfile } from "../../api/elysia";
import * as voiceApi from "../../api/voice";
import type { ElysiaProfile } from "../../api/types";
import { VoiceChannelList } from "../../components/voice/VoiceChannelList";
import { VoiceRoomBody } from "../../components/voice/VoiceRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceChannel } from "../../hooks/useVoiceChannel";
import { useVoiceStore } from "../../stores/voice";

export function GroupVoice({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const channels = useVoiceStore((s) => s.channels);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [loaded, setLoaded] = useState(false);

  const {
    currentChannelId,
    livekit,
    micEnabled,
    joining,
    join,
    leave,
    toggleMic,
    setMemberVolume,
    rejoin,
  } = useVoiceChannel();

  // 该群语音房
  const groupChannels = channels.filter((c) => c.group === groupId);

  useEffect(() => {
    let cancelled = false;
    voiceApi
      .listVoiceChannels()
      .then((list) => {
        if (!cancelled) useVoiceStore.getState().setChannels(list);
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setLoaded(true);
      });
    return () => {
      cancelled = true;
    };
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

  if (currentChannel) {
    return (
      <VoiceRoomBody
        channelName={currentChannel.name}
        livekit={livekit}
        wsConnection={wsConnection}
        micEnabled={micEnabled}
        elysiaProfile={elysiaProfile}
        groupId={currentChannel.group}
        onToggleMic={() => void toggleMic()}
        onLeave={() => void leave()}
        onRejoin={() => void rejoin()}
        onVolumeChange={setMemberVolume}
        onBack={() => void leave()}
        inputEntered // 群内子界面无底栏下滑动画
      />
    );
  }

  if (!loaded) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 96, width: "80%" }} />
      </div>
    );
  }

  if (groupChannels.length === 0) {
    return (
      <div className="group-scene-placeholder">
        <h3 className="placeholder-title">群内还没有语音房</h3>
        <p className="placeholder-desc">建一个群内语音房，一起连麦</p>
        <button type="button" className="btn btn-ghost" onClick={onExit}>
          返回聊天
        </button>
      </div>
    );
  }

  return (
    <div className={`group-voice ${isNarrow ? "" : "is-wide"}`}>
      <VoiceChannelList
        channels={groupChannels}
        currentChannelId={currentChannelId}
        joining={joining}
        onJoin={handleJoin}
      />
    </div>
  );
}
