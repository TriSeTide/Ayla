/**
 * VoicePage —— M5-3 语音主页面（路由 /voice）。
 *
 * 布局：左频道列表 + 建频道；右侧当前频道面板（成员/控制条）+ 爱莉语音面板。
 * - 进入页面：拉频道列表 + 连 Voice WS 单例（订阅在 join 后发生——非成员订阅被服务端静默忽略）；
 * - 离开页面：停止心跳但**不**自动 leave/（频道成员身份是应用层事实，由用户显式离开；
 *   心跳停了服务端超时清理会广播 left，语义一致）；
 * - 爱莉 profile 存在时展示爱莉语音面板（控制面闭环，对齐 M4-5 §5.2）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../api/elysia";
import * as voiceApi from "../api/voice";
import type { ElysiaProfile } from "../api/types";
import { ElysiaVoicePanel } from "../components/voice/ElysiaVoicePanel";
import { VoiceChannelCreate } from "../components/voice/VoiceChannelCreate";
import { VoiceChannelList } from "../components/voice/VoiceChannelList";
import { VoiceChannelPanel } from "../components/voice/VoiceChannelPanel";
import { useVoiceChannel } from "../hooks/useVoiceChannel";
import { useVoiceStore } from "../stores/voice";
import { voiceWS } from "../ws/voice";

export function VoicePage() {
  const navigate = useNavigate();
  const channels = useVoiceStore((s) => s.channels);
  const channelsLoading = useVoiceStore((s) => s.channelsLoading);
  const wsConnection = useVoiceStore((s) => s.wsConnection);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [listError, setListError] = useState<string | null>(null);

  const {
    currentChannelId,
    livekit,
    micEnabled,
    joining,
    error: joinError,
    clearError,
    join,
    leave,
    toggleMic,
    setMemberVolume,
    rejoin,
  } = useVoiceChannel();

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

  // Voice WS 单例连接（subscribe 由 join 流程触发）
  useEffect(() => {
    voiceWS.connect();
  }, []);

  // 爱莉 profile（存在则展示爱莉语音面板）
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

  const handleJoin = useCallback(
    (channelId: string) => {
      void join(channelId, { joinMuted: true });
    },
    [join],
  );

  const currentChannel = channels.find((c) => c.id === currentChannelId) ?? null;
  const notice = joinError ?? listError;

  return (
    <div className="voice-page">
      <aside className="voice-sidebar">
        <div className="chat-sidebar-head">
          <span className="chat-brand">语音</span>
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => navigate("/chat")}
            aria-label="返回聊天"
          >
            聊天
          </button>
        </div>
        <VoiceChannelCreate />
        {channelsLoading && channels.length === 0 ? (
          <div className="conv-loading">
            <div className="skeleton" style={{ height: 56, marginBottom: 8 }} />
            <div className="skeleton" style={{ height: 56 }} />
          </div>
        ) : (
          <VoiceChannelList
            channels={channels}
            currentChannelId={currentChannelId}
            joining={joining}
            onJoin={handleJoin}
          />
        )}
      </aside>

      <main className="voice-main">
        {notice && (
          <div className="chat-notice" role="alert" onClick={() => { clearError(); setListError(null); }}>
            {notice}（点击关闭）
          </div>
        )}
        {currentChannel ? (
          <VoiceChannelPanel
            channelName={currentChannel.name}
            livekit={livekit}
            wsConnection={wsConnection}
            micEnabled={micEnabled}
            elysiaProfile={elysiaProfile}
            onToggleMic={() => void toggleMic()}
            onLeave={() => void leave()}
            onRejoin={() => void rejoin()}
            onVolumeChange={setMemberVolume}
          />
        ) : (
          <div className="chat-empty">
            <h2 className="chat-empty-title">选一个语音频道加入</h2>
            <p className="chat-empty-sub">
              加入后默认静音，可手动开麦；成员音量是本地播放偏好，刷新后重置
            </p>
          </div>
        )}
        {elysiaProfile && <ElysiaVoicePanel />}
      </main>
    </div>
  );
}
