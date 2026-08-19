/**
 * GroupVoice —— 群内语音子界面（F5，R-G8）。
 *
 * 该群语音房卡片列表（filter group === groupId）+ 点卡片进房（上麦/静音/离开）。
 * 房内打字发到该群会话（复用群会话方案，开发文档 §1.9）。无语音房 → 空态 + 发起引导。
 * 群内子界面（底栏已在顶部，无独立进房动画，输入框直接显示）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../../api/elysia";
import * as voiceApi from "../../api/voice";
import type { ElysiaProfile } from "../../api/types";
import { VoiceChannelList } from "../../components/voice/VoiceChannelList";
import { VoiceRoomBody } from "../../components/voice/VoiceRoomBody";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceChannel } from "../../hooks/useVoiceChannel";
import { useAuthStore } from "../../stores/auth";
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

  // 后端已按 scope=group:xxx 过滤
  const groupChannels = channels;

  useEffect(() => {
    let cancelled = false;
    setError(null);
    voiceApi
      .listVoiceChannels({ scope: `group:${groupId}` })
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
    if (routeChannelId && currentChannelId !== routeChannelId && !joining) {
      void join(routeChannelId, { joinMuted: true });
    }
  }, [currentChannelId, join, joining, routeChannelId]);

  // 只在当前群且 URL 指向当前频道时渲染房内界面；/group/:id/voice 是列表。
  const currentChannel = routeChannelId
    ? channels.find((c) => c.id === routeChannelId && c.group === groupId) ?? null
    : null;
  const currentUser = useAuthStore((s) => s.currentUser);
  // 顶部返回只离开房间界面，保留语音连接与全局浮层；面板里的“离开频道”才真正退出。
  const handleBack = useCallback(() => {
    navigate(`/group/${groupId}/voice`);
  }, [groupId, navigate]);
  const handleLeave = useCallback(async () => {
    // 房主必须先转让房主才能离开（后端 403 强校验，前端先拦截避免状态混乱）
    if (currentChannel && currentChannel.owner_id === currentUser?.id) {
      window.confirm("你是房主，退出前应先转让房主");
      return;
    }
    try {
      await leave();
      navigate(`/group/${groupId}/voice`);
    } catch (error) {
      window.alert(error instanceof Error ? error.message : "离开语音房失败");
    }
  }, [currentChannel, currentUser, groupId, leave, navigate]);

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

  if (!loaded) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 96, width: "80%" }} />
      </div>
    );
  }

  if (error) {
    return (
      <div className="group-scene-placeholder" role="alert">
        <h3 className="placeholder-title">群内语音房加载失败</h3>
        <p className="placeholder-desc">{error}</p>
        <button type="button" className="btn btn-ghost" onClick={() => {
          setLoaded(false);
          void voiceApi.listVoiceChannels()
            .then((list) => useVoiceStore.getState().setChannels(list))
            .catch((e) => setError(e instanceof Error ? e.message : "加载群内语音房失败"))
            .finally(() => setLoaded(true));
        }}>重试</button>
      </div>
    );
  }

  if (groupChannels.length === 0) {
    return (
      <div className="group-scene-placeholder">
        <h3 className="placeholder-title">群内还没有语音房</h3>
        <p className="placeholder-desc">建一个群内语音房，一起连麦</p>
        <div className="group-voice-empty-actions">
          <button type="button" className="btn btn-ghost" onClick={onExit}>
            返回聊天
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className={`group-voice ${isNarrow ? "" : "is-wide"}`}>
      {profileError && <div className="chat-notice" role="alert">爱莉入口暂不可用：{profileError}</div>}
      <div className="group-voice-head">
        <div>
          <h3 className="group-voice-title">群内语音房</h3>
          <p className="group-voice-desc">选择一个房间加入，或点击右下角创建新的群内语音房</p>
        </div>
      </div>
      <VoiceChannelList
        channels={groupChannels}
        currentChannelId={currentChannelId}
        joining={joining}
        onJoin={handleJoin}
      />
    </div>
  );
}
