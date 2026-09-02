/**
 * MessageInput —— 输入区：乐观发送、媒体缩略图队列、剪贴板粘贴、引用条、@ 能力（M8，仅群聊）。
 *
 * M7 语义：发送不阻塞输入；图片/视频多选先入队，点发送统一上传；粘贴媒体进队列。
 * M8 @：contentEditable 编辑器，输入 @ 弹出群成员选择器（MentionPicker），选中生成
 * 不可拆分 @Token（contenteditable=false span，浏览器原生整体删除），发送时转为
 * 结构化 segments（text + mention 交错，媒体段追加尾部）。
 */
import { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from "react";
import type { ChatMessage, ConversationMember, DraftBlock } from "../../api/types";
import { useChatDraftsStore } from "../../stores/chatDrafts";
import { useAuthStore } from "../../stores/auth";
import { sendMessage, sendOptimistic, type PickedMediaItem } from "../../hooks/useChat";
import { uploadMediaFile, validateMediaFile } from "../../api/media";
import { IconImage, IconClose, IconMic, IconSend, IconFile, IconEmoji } from "../icons";
import { useTyping } from "../../hooks/useTyping";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useVoiceRecorder, isVoiceRecordingSupported, formatDuration as formatRecDuration, type VoiceRecording } from "../../hooks/useVoiceRecorder";
import { segmentPreview } from "../../utils/segment";
import { EmojiPackPanel } from "./EmojiPackPanel";
import {
  blocksHasMention,
  blocksText,
  detectMentionAtCaret,
  extractBlocks,
  insertMentionAtCaret,
  insertMentionToken,
  parseBlocks,
  renderBlocksToDOM,
  serializeBlocks,
} from "../../utils/mention";
import { MentionPicker } from "./MentionPicker";

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

export interface MessageInputHandle {
  /** 在编辑器光标处插入 @某用户（长按头像 @ 触发，M8） */
  insertMention: (userId: string, name: string) => void;
}

export interface MessageInputProps {
  convId: string;
  quote: ChatMessage | null;
  onQuoteClear: () => void;
  /** 群成员（仅群聊启用 @）；私聊不传 */
  members?: ConversationMember[];
}

export const MessageInput = forwardRef<MessageInputHandle, MessageInputProps>(
  function MessageInput({ convId, quote, onQuoteClear, members }, ref) {
    const setDraft = useChatDraftsStore((state) => state.setDraft);
    const clearDraft = useChatDraftsStore((state) => state.clearDraft);
    const [blocks, setBlocks] = useState<DraftBlock[]>([]);
    /** 待发送媒体队列（本地预览，未上传；发送时统一上传） */
    const [picked, setPicked] = useState<PickedMediaItem[]>([]);
    const [voiceUploading, setVoiceUploading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [failedVoice, setFailedVoice] = useState<FailedVoice | null>(null);
    const [mentionOpen, setMentionOpen] = useState(false);
    const [mentionQuery, setMentionQuery] = useState("");
    /** 群表情包面板（任务 03）：宽屏向上弹窗、窄屏向下展开 */
    const [emojiOpen, setEmojiOpen] = useState(false);
    const editorRef = useRef<HTMLDivElement>(null);
    const voice = useVoiceRecorder();
    const isNarrow = useMediaQuery(NARROW_QUERY);
    // 群聊才有 members：@ 与群表情包按钮均仅群聊展示（私信不显示表情包按钮）
    const isGroup = !!members && members.length > 0;
    // 群聊已删除「对方正在输入」功能：不声明 typing（私聊保留）
    const { onInput } = useTyping(isGroup ? null : convId);
    const enableMention = isGroup;
    // 当前用户在群中的角色（表情面板加号兜底显示用）
    const currentUser = useAuthStore((s) => s.currentUser);
    const myRole = useMemo(
      () => members?.find((m) => m.user.id === currentUser?.id)?.role,
      [members, currentUser?.id],
    );

    // user_id → 显示名（草稿恢复 + @Token 用）
    const nameOf = useCallback(
      (id: string) => {
        const m = members?.find((x) => x.user.id === id);
        return m ? m.user.nickname || m.user.username : undefined;
      },
      [members],
    );
    const nameOfRef = useRef(nameOf);
    nameOfRef.current = nameOf;

    // 切换会话 → 恢复草稿（渲染到 DOM + 重置状态）；不随 draft 实时变化（避免光标跳）
    useEffect(() => {
      const el = editorRef.current;
      if (!el) return;
      const d = useChatDraftsStore.getState().getDraft(convId);
      const parsed = parseBlocks(d, nameOfRef.current);
      renderBlocksToDOM(el, parsed);
      setBlocks(parsed);
      setMentionOpen(false);
      setMentionQuery("");
      setEmojiOpen(false);
      setError(null);
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [convId]);

    /** 校验并加入待发送队列（选文件/粘贴共用） */
    const enqueueFiles = (files: File[]) => {
      const added: PickedMediaItem[] = [];
      let hasFile = false;
      for (const file of files) {
        const { error, kind } = validateMediaFile(file);
        if (error) {
          setError(error);
          continue;
        }
        if (kind === "file") hasFile = true;
        added.push({
          id: newPickId(),
          kind,
          mimeType: file.type,
          // file 无缩略图预览：不建 objectURL（渲染走文件名，省内存）
          url: kind === "file" ? "" : URL.createObjectURL(file),
          file,
        });
      }
      if (added.length > 0) {
        setPicked((prev) => {
          // 单文件互斥：file 与图片/视频不能混排（file 是单媒体消息契约）。
          // 新选含 file → 丢弃旧的图片/视频；旧队列已有 file 且新增图片/视频 → 丢弃旧 file。
          const prevHasFile = prev.some((p) => p.kind === "file");
          if (hasFile || prevHasFile) {
            for (const p of prev) {
              if (p.url) URL.revokeObjectURL(p.url);
            }
            return added;
          }
          return [...prev, ...added];
        });
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

    /** 编辑器输入 → 提取 blocks + 存草稿 + typing + @ 检测 */
    const handleEditorInput = () => {
      const el = editorRef.current;
      if (!el) return;
      const nextBlocks = extractBlocks(el);
      setBlocks(nextBlocks);
      setDraft(convId, serializeBlocks(nextBlocks));
      onInput();
      if (enableMention) {
        const detected = detectMentionAtCaret(el);
        if (detected) {
          setMentionQuery(detected.query);
          setMentionOpen(true);
        } else {
          setMentionOpen(false);
        }
      }
    };

    /** 选中成员 → 插入不可拆分 @Token */
    const handleSelectMention = (member: ConversationMember) => {
      const el = editorRef.current;
      if (!el) return;
      const name = member.user.nickname || member.user.username;
      insertMentionAtCaret(el, member.user.id, name);
      const nextBlocks = extractBlocks(el);
      setBlocks(nextBlocks);
      setDraft(convId, serializeBlocks(nextBlocks));
      setMentionOpen(false);
      setMentionQuery("");
      el.focus();
    };

    /** 长按头像 @：在光标处直接插入 @Token（不依赖 @ 前缀），并同步草稿 */
    const insertMention = useCallback(
      (userId: string, name: string) => {
        const el = editorRef.current;
        if (!el) return;
        insertMentionToken(el, userId, name);
        const nextBlocks = extractBlocks(el);
        setBlocks(nextBlocks);
        setDraft(convId, serializeBlocks(nextBlocks));
        setMentionOpen(false);
        setMentionQuery("");
        el.focus();
      },
      [convId, setDraft],
    );

    useImperativeHandle(ref, () => ({ insertMention }), [insertMention]);

    /** 乐观发送：立即插入气泡，后台上传+发送；不阻塞继续输入 */
    const submit = () => {
      const text = blocksText(blocks).trim();
      const hasMention = blocksHasMention(blocks);
      if ((!text && picked.length === 0 && !hasMention) || !convId || voice.recording) return;
      sendOptimistic(convId, {
        blocks,
        picked,
        replyTo: quote ? Number(quote.id) : null,
      });
      // 发送即清空（消息已进列表），可立即输入下一条。
      const el = editorRef.current;
      if (el) el.innerHTML = "";
      setBlocks([]);
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
    const canSend =
      (blocksText(blocks).trim().length > 0 || blocksHasMention(blocks) || picked.length > 0) &&
      !voice.recording;
    const placeholder = isNarrow
      ? "输入消息"
      : "输入消息，回车发送（Shift+Enter 换行）；可粘贴图片/视频，群聊输入 @ 可提及成员";

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
                ) : p.kind === "file" ? (
                  <span className="picked-file" title={p.file.name}>
                    <IconFile width={16} height={16} />
                    <span className="picked-file-name">{p.file.name}</span>
                  </span>
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
        {mentionOpen && enableMention && (
          <MentionPicker members={members!} query={mentionQuery} onSelect={handleSelectMention} />
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
              {/* 宽屏：工具按钮与输入框横排（图片/文件/语音/表情包） */}
              {!isNarrow && (
                <div className="composer-tools">
                  <label className="composer-tool-btn" aria-label="发送图片或视频">
                    <IconImage width={18} height={18} />
                    <input type="file" accept="image/*,video/*" multiple hidden onChange={(e) => {
                      const files = Array.from(e.target.files ?? []);
                      e.target.value = "";
                      if (files.length === 0) return;
                      enqueueFiles(files);
                    }} />
                  </label>
                  <label className="composer-tool-btn" aria-label="发送文件" title="发送文件（任意格式，单个）">
                    <IconFile width={18} height={18} />
                    <input
                      type="file"
                      hidden
                      onChange={(e) => {
                        const files = Array.from(e.target.files ?? []);
                        e.target.value = "";
                        if (files.length === 0) return;
                        enqueueFiles(files);
                      }}
                    />
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
                  {isGroup && (
                    <button
                      type="button"
                      className="composer-tool-btn"
                      onClick={() => setEmojiOpen((v) => !v)}
                      aria-label="群表情包"
                      aria-expanded={emojiOpen}
                      title="群表情包"
                    >
                      <IconEmoji width={18} height={18} />
                    </button>
                  )}
                </div>
              )}
              <div
                ref={editorRef}
                className="field composer-input composer-editor"
                contentEditable
                suppressContentEditableWarning
                role="textbox"
                aria-multiline="true"
                aria-label="消息输入框"
                data-placeholder={placeholder}
                onInput={handleEditorInput}
                onKeyDown={(e) => {
                  if (mentionOpen && e.key === "Escape") {
                    e.preventDefault();
                    setMentionOpen(false);
                    return;
                  }
                  if (emojiOpen && e.key === "Escape") {
                    e.preventDefault();
                    setEmojiOpen(false);
                    return;
                  }
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault();
                    submit();
                  }
                }}
                onPaste={(e) => {
                  // 粘贴图片/视频文件 → 进待发送队列（阻止默认，避免 contentEditable 混入 HTML）
                  const items = Array.from(e.clipboardData?.items ?? []);
                  const files = items
                    .filter((it) => it.kind === "file")
                    .map((it) => it.getAsFile())
                    .filter((f): f is File => f != null);
                  const mediaFiles = files.filter(
                    (f) => f.type.startsWith("image/") || f.type.startsWith("video/"),
                  );
                  if (mediaFiles.length > 0) {
                    e.preventDefault();
                    enqueueFiles(mediaFiles);
                  }
                }}
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
            </>
          )}
        </div>
        {/* 窄屏：输入框下方四个工具按钮（图片/语音/表情包/文件），面板向下展开 */}
        {isNarrow && !voice.recording && (
          <div className="composer-tools composer-tools-narrow" role="toolbar" aria-label="消息工具">
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
            {isGroup && (
              <button
                type="button"
                className="composer-tool-btn"
                onClick={() => setEmojiOpen((v) => !v)}
                aria-label="群表情包"
                aria-expanded={emojiOpen}
                title="群表情包"
              >
                <IconEmoji width={18} height={18} />
              </button>
            )}
            <label className="composer-tool-btn" aria-label="发送文件" title="发送文件（任意格式，单个）">
              <IconFile width={18} height={18} />
              <input
                type="file"
                hidden
                onChange={(e) => {
                  const files = Array.from(e.target.files ?? []);
                  e.target.value = "";
                  if (files.length === 0) return;
                  enqueueFiles(files);
                }}
              />
            </label>
          </div>
        )}
        {emojiOpen && (
          <EmojiPackPanel convId={convId} myRole={myRole} onClose={() => setEmojiOpen(false)} />
        )}
      </div>
    );
  },
);
