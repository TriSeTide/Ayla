/**
 * MessageInput —— 输入区：乐观发送（不阻塞输入）、多选媒体缩略图队列、剪贴板粘贴、引用条。
 *
 * M7 语义：
 * - 发送不再等待网络：点击发送即插入乐观气泡（左上角加载态），可继续输入下一条；
 * - 图片/视频多选后先进入输入框上方的缩略图条（本地预览，未上传），点发送时统一上传并发送；
 * - 支持直接粘贴剪贴板图片/视频（自动进队列，不自动发送）；
 * - 纯文本走旧 text 契约；带媒体走混排 segments（type=mixed）。
 */
import { useEffect, useState } from "react";
import type { ChatMessage } from "../../api/types";
import { useChatDraftsStore } from "../../stores/chatDrafts";
import { sendMessage, sendOptimistic, type PickedMediaItem } from "../../hooks/useChat";
import { uploadMediaFile, validateMediaFile } from "../../api/media";
import { IconImage, IconClose, IconMic, IconSend } from "../icons";
import { useTyping } from "../../hooks/useTyping";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceRecorder, isVoiceRecordingSupported, formatDuration as formatRecDuration, type VoiceRecording } from "../../hooks/useVoiceRecorder";
import { segmentPreview } from "../../utils/segment";

interface FailedVoice {
  blob: Blob;
  mimeType: string;
  duration: number;
}

function newPickId() {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random()}`;
}

export function MessageInput({
  convId,
  quote,
  onQuoteClear,
}: {
  convId: string;
  quote: ChatMessage | null;
  onQuoteClear: () => void;
}) {
  const draft = useChatDraftsStore((state) => state.drafts[convId] ?? "");
  const setDraft = useChatDraftsStore((state) => state.setDraft);
  const clearDraft = useChatDraftsStore((state) => state.clearDraft);
  const [text, setText] = useState(draft);
  /** 待发送媒体队列（本地预览，未上传；发送时统一上传） */
  const [picked, setPicked] = useState<PickedMediaItem[]>([]);
  const [voiceUploading, setVoiceUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [failedVoice, setFailedVoice] = useState<FailedVoice | null>(null);
  const voice = useVoiceRecorder();
  const { onInput } = useTyping(convId || null);
  const isNarrow = useMediaQuery(NARROW_QUERY);

  useEffect(() => {
    setText(draft);
    setError(null);
  }, [convId, draft]);

  /** 校验并加入待发送队列（选文件/粘贴共用） */
  const enqueueFiles = (files: File[]) => {
    const added: PickedMediaItem[] = [];
    for (const file of files) {
      const { error, kind } = validateMediaFile(file);
      if (error) {
        setError(error);
        continue;
      }
      added.push({
        id: newPickId(),
        kind,
        mimeType: file.type,
        url: URL.createObjectURL(file),
        file,
      });
    }
    if (added.length > 0) {
      setPicked((prev) => [...prev, ...added]);
      setError(null);
    }
  };

  const removePicked = (id: string) => {
    setPicked((prev) => {
      const item = prev.find((p) => p.id === id);
      if (item) URL.revokeObjectURL(item.url);
      return prev.filter((p) => p.id !== id);
    });
  };

  /** 乐观发送：立即插入气泡，后台上传+发送；不阻塞继续输入 */
  const submit = () => {
    const textVal = text.trim();
    if ((!textVal && picked.length === 0) || !convId || voice.recording) return;
    sendOptimistic(convId, {
      text: textVal,
      picked,
      replyTo: quote ? Number(quote.id) : null,
    });
    // 发送即清空（消息已进列表），可立即输入下一条。
    // 注意：picked 的 objectURL 所有权已转移给乐观气泡（由气泡组件在替换/删除卸载时
    // 统一 revoke），这里只能清空引用、绝不能 revoke —— 否则气泡立即变破图。
    setText("");
    clearDraft(convId);
    setPicked([]);
    setError(null);
    if (quote) onQuoteClear();
  };

  /** 语音（旧路径：录音完成 → 上传 → 发送；composer 显示上传中） */
  const sendVoice = async (rec: VoiceRecording) => {
    if (voiceUploading || !convId) return;
    setVoiceUploading(true);
    setError(null);
    setFailedVoice(null);
    try {
      const file = new File([rec.blob], "voice.webm", { type: rec.mimeType || "audio/webm" });
      const uploaded = await uploadMediaFile(file, "voice");
      await sendMessage(convId, "", {
        type: "voice",
        replyTo: quote ? Number(quote.id) : null,
        idempotencyKey: newPickId(),
        mediaId: uploaded.media_id,
      });
    } catch (err) {
      setFailedVoice({ blob: rec.blob, mimeType: rec.mimeType, duration: rec.duration });
      setError(err instanceof Error ? err.message : "语音发送失败");
    } finally {
      setVoiceUploading(false);
    }
  };

  // 录音停止 → 直接上传发送；过短（<0.8s）视为无效丢弃
  const stopAndSend = async () => {
    const rec = await voice.stop();
    if (rec && rec.duration >= 0.8) await sendVoice(rec);
  };

  const retryVoice = async () => {
    const fv = failedVoice;
    if (!fv) return;
    setFailedVoice(null);
    setError(null);
    await sendVoice({ blob: fv.blob, mimeType: fv.mimeType, duration: fv.duration });
  };

  const quotePreview = quote ? (segmentPreview(quote.segments) ?? (quote.content || "…")) : null;
  const canSend = (text.trim().length > 0 || picked.length > 0) && !voice.recording;

  return (
    <div className="composer">
      {quote && quotePreview != null && (
        <div className="quote-bar">
          <div className="quote-bar-body">
            <span className="quote-bar-label">引用回复</span>
            <span className="quote-bar-text">{quotePreview}</span>
          </div>
          <button
            type="button"
            className="quote-bar-cancel"
            onClick={onQuoteClear}
            aria-label="取消引用"
          >
            <IconClose width={14} height={14} />
          </button>
        </div>
      )}
      {picked.length > 0 && (
        <div className="composer-picked" role="group" aria-label="待发送媒体">
          {picked.map((p) => (
            <div key={p.id} className="picked-thumb" data-kind={p.kind}>
              {p.kind === "video" ? (
                <video src={p.url} className="picked-video" preload="metadata" muted playsInline tabIndex={-1} />
              ) : (
                <img src={p.url} alt="待发送图片" className="picked-img" />
              )}
              {p.kind === "video" && <span className="picked-play" aria-hidden="true">▶</span>}
              <button
                type="button"
                className="picked-remove"
                onClick={() => removePicked(p.id)}
                aria-label="移除媒体"
              >
                <IconClose width={12} height={12} />
              </button>
            </div>
          ))}
        </div>
      )}
      {voiceUploading && <div className="composer-uploading" role="status">语音上传中…</div>}
      {error && (
        <div className="composer-error" role="alert">
          <span>{error}</span>
          {failedVoice && (
            <button type="button" className="msg-action-btn" onClick={() => void retryVoice()} disabled={voiceUploading}>重试语音</button>
          )}
        </div>
      )}
      {voice.error && !error && (
        <div className="composer-error" role="alert">
          <span>{voice.error}</span>
          <button type="button" className="msg-action-btn" onClick={voice.clearError}>关闭</button>
        </div>
      )}
      <div className="composer-row">
        {voice.recording ? (
          <>
            <span className="voice-recording-hint" role="status">
              <span className="voice-rec-dot" />
              正在录音 {formatRecDuration(voice.elapsed)}
            </span>
            <button
              type="button"
              className="composer-tool-btn composer-voice-stop"
              onClick={() => void stopAndSend()}
              aria-label="停止并发送语音"
              disabled={voiceUploading}
            >
              <IconSend width={18} height={18} />
            </button>
            <button
              type="button"
              className="composer-tool-btn composer-voice-cancel"
              onClick={() => voice.cancel()}
              aria-label="取消录音"
              disabled={voiceUploading}
            >
              <IconClose width={16} height={16} />
            </button>
          </>
        ) : (
          <>
            <label className="composer-tool-btn" aria-label="发送图片或视频">
              <IconImage width={18} height={18} />
              <input type="file" accept="image/*,video/*" multiple hidden onChange={(e) => {
                const files = Array.from(e.target.files ?? []);
                e.target.value = "";
                if (files.length === 0) return;
                enqueueFiles(files);
              }} />
            </label>
            {isVoiceRecordingSupported() && (
              <button
                type="button"
                className="composer-tool-btn composer-voice-btn"
                onClick={() => void voice.start()}
                aria-label="发送语音"
                title="录制语音消息"
                disabled={voice.recording}
              >
                <IconMic width={18} height={18} />
              </button>
            )}
          </>
        )}
        <textarea
          className="field composer-input"
          value={text}
          onChange={(e) => {
            const value = e.target.value;
            setText(value);
            setDraft(convId, value);
            onInput();
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              submit();
            }
          }}
          onPaste={(e) => {
            // 粘贴图片/视频文件 → 进待发送队列（不自动发送）；文本走默认粘贴
            const items = Array.from(e.clipboardData?.items ?? []);
            const files = items
              .filter((it) => it.kind === "file")
              .map((it) => it.getAsFile())
              .filter((f): f is File => f != null);
            const mediaFiles = files.filter(
              (f) => f.type.startsWith("image/") || f.type.startsWith("video/"),
            );
            if (mediaFiles.length > 0) enqueueFiles(mediaFiles);
          }}
          placeholder={isNarrow ? "输入消息" : "输入消息，回车发送（Shift+Enter 换行）；可粘贴图片/视频"}
          rows={2}
        />
        <button
          type="button"
          className="btn btn-primary composer-send"
          onClick={submit}
          disabled={!canSend || !convId}
        >
          <IconSend width={15} height={15} />
          发送
        </button>
      </div>
    </div>
  );
}
