/**
 * VoiceRoomBody —— 语音房整页（进房态）。
 * 房内聊天使用 voice-chat 独立接口，不写入群聊 Message；支持文字与图片。
 */
import { useEffect, useRef, useState } from "react";
import * as voiceApi from "../../api/voice";
import { uploadMediaFile, mediaContentUrl, resolveMediaPath } from "../../api/media";
import type { ElysiaProfile, VoiceChatMessage, VoiceChannelDescriptor } from "../../api/types";
import { FavoriteButton } from "../FavoriteButton";
import { ScrollingText } from "../ScrollingText";
import { ScrollingTags } from "../ScrollingTags";
import { IconBack, IconImage, IconSend } from "../icons";
import { ResourceImage } from "../ResourceImage";
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { useAuthStore } from "../../stores/auth";
import { VoiceChannelPanel } from "./VoiceChannelPanel";
import { getVisibilityLabels } from "../../utils/visibility";
import { useRevealOnEnter } from "../../hooks/useRevealOnEnter";
import { voiceWS } from "../../ws/voice";

export function VoiceRoomBody({
  channelId,
  channelName,
  ownerId,
  channel,
  livekit,
  wsConnection,
  elysiaProfile,
  onToggleMic,
  onLeave,
  onRejoin,
  onVolumeChange,
  onLocalVolumeChange,
  onToggleMemberMuted,
  onBack,
  onDeleteChannel,
  inputEntered,
}: {
  channelId?: string;
  ownerId?: string;
  /** 旧调用方兼容字段；房内消息不再根据群归属路由。 */
  groupId?: string | null;
  channelName: string;
  /** 完整的频道对象，用于显示标签等信息 */
  channel?: VoiceChannelDescriptor | null;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  elysiaProfile: ElysiaProfile | null;
  onToggleMic: () => void;
  onLeave: () => void;
  onRejoin: () => void;
  onVolumeChange: (userId: string, volume: number) => void;
  onLocalVolumeChange: (volume: number) => void;
  onToggleMemberMuted: (userId: string) => void;
  onBack: () => void;
  onDeleteChannel?: () => void;
  inputEntered: boolean;
}) {
  const currentUser = useAuthStore((state) => state.currentUser);
  const [text, setText] = useState("");
  const [messages, setMessages] = useState<VoiceChatMessage[]>([]);
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [chatExpanded, setChatExpanded] = useState(false);
  // 房内聊天未读数（红点）：只在聊天栏收起且收到他人新消息时累加，展开即清零
  const [unreadCount, setUnreadCount] = useState(0);
  // 聊天栏展开态 ref：WS 回调内判断是否累加未读，避免把 chatExpanded 加入依赖导致重复订阅
  const chatExpandedRef = useRef(false);
  // 已见消息 id：WS 回播 / 乐观发送去重，未读只在"真正新消息"时累加
  const seenIdsRef = useRef<Set<string>>(new Set());
  // 聊天列表滚动容器：展开时滚动到底部显示最新消息
  const chatListRef = useRef<HTMLDivElement>(null);
  // 进房体统一入场动画（与直播间同源：成员面板先浮入，聊天卡随后）
  const { step } = useRevealOnEnter(true);

  useEffect(() => {
    if (!channelId) return;
    let cancelled = false;
    seenIdsRef.current = new Set();
    setMessages([]);
    setUnreadCount(0);
    setError(null);
    void voiceApi.listVoiceChatMessages(channelId).then((items) => {
      if (cancelled) return;
      items.forEach((m) => seenIdsRef.current.add(m.id));
      setMessages(items);
    }).catch((err) => {
      if (!cancelled) setError(err instanceof Error ? err.message : "加载房内聊天失败");
    });
    return () => { cancelled = true; };
  }, [channelId]);

  // 房内聊天 WS 热更新：订阅 voice.chat.message 帧，按 message.id 幂等去重 append。
  // 后端先 group_send 广播、后返回 POST 响应，WS 回播可能先于 sendMessage 的乐观 append 到达，
  // 因此显示去重必须双向（prev.some 按 id 去重），seenIdsRef 只用于"真正新消息"的未读计数。
  useEffect(() => {
    if (!channelId) return;
    const off = voiceWS.onFrame((frame) => {
      if (frame.type !== "voice.chat.message") return;
      const msg = frame.data;
      if (String(msg.channel_id) !== String(channelId)) return;
      const isNew = !seenIdsRef.current.has(msg.id);
      seenIdsRef.current.add(msg.id);
      // 显示去重：无论乐观 append 与 WS 回播谁先到，同一 id 只渲染一条
      setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]));
      if (!isNew) return;
      // 未读仅在聊天栏收起、且非自己发送时累加
      const selfId = useAuthStore.getState().currentUser?.id;
      const isSelf = selfId != null && String(msg.sender.user_id) === String(selfId);
      if (!chatExpandedRef.current && !isSelf) {
        setUnreadCount((n) => n + 1);
      }
    });
    return off;
  }, [channelId]);

  // 展开聊天栏即清空未读红点，并把列表滚动到底部显示最新消息；同步维护 ref 供 WS 回调读取
  useEffect(() => {
    chatExpandedRef.current = chatExpanded;
    if (chatExpanded) {
      setUnreadCount(0);
      const el = chatListRef.current;
      if (el) el.scrollTop = el.scrollHeight;
    }
  }, [chatExpanded]);

  const sendMessage = async (mediaId?: string | null) => {
    if (!channelId || sending) return;
    const content = text.trim();
    if (!content && !mediaId) return;
    setSending(true);
    setError(null);
    try {
      const message = await voiceApi.sendVoiceChatMessage(channelId, {
        content: content || "图片",
        media_id: mediaId ?? null,
      });
      seenIdsRef.current.add(message.id);
      // 乐观 append 同样按 id 去重：若 WS 回播已先到并渲染过，这里跳过，避免双气泡
      setMessages((prev) => (prev.some((m) => m.id === message.id) ? prev : [...prev, message]));
      setText("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "发送失败，请重试");
    } finally {
      setSending(false);
    }
  };

  const sendImage = async (file: File) => {
    if (!channelId || sending || uploading) return;
    setUploading(true);
    setError(null);
    try {
      const uploaded = await uploadMediaFile(file, "image");
      await sendMessage(uploaded.media_id);
    } catch (err) {
      setError(err instanceof Error ? err.message : "图片发送失败，请重试");
    } finally {
      setUploading(false);
    }
  };

  const chatList = (
    <div className="voice-room-chat-list" aria-live="polite" ref={chatListRef}>
      {messages.map((message) => (
        <div key={message.id} className="voice-room-chat-message">
          <span className="voice-room-chat-sender">{message.sender.nickname}：</span>
          {message.media_id && message.media && (
            <ResourceImage
              src={resolveMediaPath(message.media.thumbnail) ?? mediaContentUrl(message.media_id)}
              alt={message.content || "房内聊天图片"}
              className="voice-room-chat-image"
              loading="lazy"
              fallback={<span className="skeleton" style={{ width: 120, height: 80, borderRadius: 8 }} />}
            />
          )}
          {message.content !== "图片" && <span>{message.content}</span>}
        </div>
      ))}
    </div>
  );

  const composer = (
    <div
      className="voice-room-composer"
      style={{
        transform: inputEntered ? "translateY(0)" : "translateY(100%)",
        transition: "transform 250ms var(--ease-out)",
      }}
    >
      <div className="composer-row">
        <label className="composer-tool-btn" aria-label="发送房内图片">
          <IconImage width={18} height={18} />
          <input
            type="file"
            accept="image/*"
            hidden
            onChange={async (event) => {
              const file = event.target.files?.[0];
              event.target.value = "";
              if (file) await sendImage(file);
            }}
          />
        </label>
        <textarea
          className="field composer-input"
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.nativeEvent.isComposing) {
              event.preventDefault();
              void sendMessage();
            }
          }}
          placeholder="在语音房内聊天"
          rows={1}
          disabled={sending || uploading}
        />
        <button
          type="button"
          className="btn btn-primary"
          disabled={sending || uploading || !text.trim()}
          onClick={() => void sendMessage()}
          aria-label="发送语音房消息"
        >
          <IconSend width={15} height={15} />
        </button>
        <button
          type="button"
          className="voice-room-chat-toggle-btn"
          onClick={() => setChatExpanded(!chatExpanded)}
          aria-label={chatExpanded ? "收起聊天" : "展开聊天"}
          aria-expanded={chatExpanded}
        >
          {chatExpanded ? "▼" : "▲"}
          {unreadCount > 0 && (
            <span className="voice-room-chat-count">{unreadCount > 99 ? "99+" : unreadCount}</span>
          )}
        </button>
      </div>
    </div>
  );

  return (
    <div className="voice-room-body">
      <header className="voice-room-head">
        <button type="button" className="icon-btn-40" onClick={onBack} aria-label="返回">
          <IconBack width={20} height={20} />
        </button>
        <ScrollingText text={channelName} className="voice-room-title" />
        {channel && (
          <ScrollingTags labels={getVisibilityLabels(channel)} tagClassName="post-card-tag" className="voice-room-tags" />
        )}
        {channelId != null && <FavoriteButton targetType="voice" targetId={channelId} compact />}
        {ownerId === currentUser?.id && onDeleteChannel && (
          <button type="button" className="btn btn-danger" onClick={onDeleteChannel}>删除房间</button>
        )}
      </header>

      <div className="voice-room-layout">
        <section className={`voice-room-voice-card reveal ${step === 1 ? "is-in" : ""}`} aria-label="语音成员">
          <VoiceChannelPanel
            channelName={channelName}
            channelId={channelId}
            ownerId={ownerId}
            livekit={livekit}
            wsConnection={wsConnection}
            elysiaProfile={elysiaProfile}
            onToggleMic={onToggleMic}
            onLeave={onLeave}
            onRejoin={onRejoin}
            onVolumeChange={onVolumeChange}
            onLocalVolumeChange={onLocalVolumeChange}
            onToggleMemberMuted={onToggleMemberMuted}
          />
        </section>

        {channelId != null && (
          <section className={`voice-room-chat-card reveal ${step === 1 ? "is-in" : ""} ${chatExpanded ? "is-expanded" : ""}`} aria-label="房内聊天">
            <header className="voice-room-chat-card-head">
              <span className="voice-room-chat-title">房内聊天</span>
              <span className="voice-room-chat-count-label">{messages.length} 条消息</span>
            </header>
            {chatList}
            {error && <div className="live-form-error" role="alert">{error}</div>}
            {composer}
          </section>
        )}
      </div>

    </div>
  );
}
