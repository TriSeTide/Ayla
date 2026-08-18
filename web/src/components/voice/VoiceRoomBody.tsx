/**
 * VoiceRoomBody —— 语音房整页（进房态）。
 * 房内聊天使用 voice-chat 独立接口，不写入群聊 Message；支持文字与图片。
 */
import { useEffect, useState } from "react";
import * as voiceApi from "../../api/voice";
import { uploadMediaFile, mediaContentUrl, resolveMediaPath } from "../../api/media";
import type { ElysiaProfile, VoiceChatMessage } from "../../api/types";
import { FavoriteButton } from "../FavoriteButton";
import { IconImage, IconSend } from "../icons";
import { ResourceImage } from "../ResourceImage";
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { useAuthStore } from "../../stores/auth";
import { VoiceChannelPanel } from "./VoiceChannelPanel";

export function VoiceRoomBody({
  channelId,
  channelName,
  ownerId,
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

  useEffect(() => {
    if (!channelId) return;
    let cancelled = false;
    setMessages([]);
    setError(null);
    void voiceApi.listVoiceChatMessages(channelId).then((items) => {
      if (!cancelled) setMessages(items);
    }).catch((err) => {
      if (!cancelled) setError(err instanceof Error ? err.message : "加载房内聊天失败");
    });
    return () => { cancelled = true; };
  }, [channelId]);

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
      setMessages((prev) => [...prev, message]);
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

  return (
    <div className="voice-room-body">
      <header className="voice-room-head">
        <button type="button" className="msg-action-btn" onClick={onBack} aria-label="返回">
          ← 返回
        </button>
        <span className="voice-room-title">{channelName}</span>
        {channelId != null && <FavoriteButton targetType="voice" targetId={channelId} compact />}
        {ownerId === currentUser?.id && onDeleteChannel && <button type="button" className="btn btn-danger" onClick={onDeleteChannel}>删除房间</button>}
      </header>

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

      {channelId != null && (
        <div
          className="voice-room-input"
          style={{
            transform: inputEntered ? "translateY(0)" : "translateY(100%)",
            transition: "transform 250ms var(--ease-out)",
          }}
        >
          <div className="voice-room-chat-list" aria-live="polite">
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
          {error && <div className="live-form-error" role="alert">{error}</div>}
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
          </div>
        </div>
      )}
    </div>
  );
}
