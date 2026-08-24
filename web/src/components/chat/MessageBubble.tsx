/**
 * MessageBubble —— 单条消息气泡。
 *
 * 视觉（design.md §4 Chat Bubbles）：
 * - 自己：冰蓝渐变，右下 6px 小角；爱莉：樱粉渐变 + grape 字（专属，不可复用）；
 *   其他用户：玻璃底；
 * - 媒体消息（image/emoji/voice/file/video）走 MediaContent 真实渲染（M5-2.1）；
 * - 引用回复：左 3px ice 竖条 + 弱化一层；
 * - 撤回态弱化 + 「已撤回」标签。
 */
import type { ChatMessage } from "../../api/types";
import { Avatar } from "../Avatar";
import { FavoriteButton } from "../FavoriteButton";
import { RECALL_SECONDS } from "../../hooks/useChat";
import { MediaContent } from "./MediaContent";
import { IconQuote, IconUndo, IconClose } from "../icons";

function timeAgo(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** 撤回窗口判断（仅自己、未撤回、created_at 在 120s 内） */
export function canRecall(
  message: ChatMessage,
  currentUserId: string | null | undefined,
): boolean {
  if (message.sender_id !== currentUserId) return false;
  if (message.status === "recalled") return false;
  const created = new Date(message.created_at).getTime();
  if (Number.isNaN(created)) return false;
  return (Date.now() - created) / 1000 <= RECALL_SECONDS;
}

const MEDIA_TYPES = new Set(["image", "voice", "file", "emoji", "video", "mixed"]);

export function MessageBubble({
  message,
  isSelf,
  isElysia = false,
  senderName,
  senderAvatar,
  senderAvatarLabel,
  onSenderClick,
  quoteText,
  onQuote,
  onRecall,
  onRetry,
  onRemove,
  onCancel,
}: {
  message: ChatMessage;
  isSelf: boolean;
  /** 爱莉消息（专属气泡样式），由父级按 sender 判定 */
  isElysia?: boolean;
  /** 群聊显示发送者名 */
  senderName?: string | null;
  /** 发送者头像 URL（气泡行左右显示，design.md §4 Chat Bubbles） */
  senderAvatar?: string | null;
  /** 无头像图时的首字符标签 */
  senderAvatarLabel?: string | null;
  /** 头像点击 → 个人主页 */
  onSenderClick?: () => void;
  /** 被引用消息的预览文本（父级解析） */
  quoteText?: string | null;
  onQuote?: (msg: ChatMessage) => void;
  onRecall?: (msg: ChatMessage) => void;
  /** 乐观发送失败：重试（重新上传+发送，幂等键复用） */
  onRetry?: (msg: ChatMessage) => void;
  /** 乐观消息删除（本地丢弃） */
  onRemove?: (msg: ChatMessage) => void;
  /** 乐观发送中：取消上传（abort + 删除气泡） */
  onCancel?: (msg: ChatMessage) => void;
}) {
  const recalled = message.status === "recalled";
  const isMedia = MEDIA_TYPES.has(message.type);

  const bubbleClass = recalled
    ? "bubble bubble-other recalled"
    : isSelf
      ? "bubble bubble-self"
      : isElysia
        ? "bubble bubble-elysia"
        : "bubble bubble-other";

  // 发送者头像：只要有发送者信息就显示（无头像图时 Avatar 回退首字符光环），
  // 撤销/系统消息不显示；己方在气泡右侧、对方在气泡左侧（msg-row flex 布局）。
  const showSenderHalo =
    !recalled && message.type !== "system" && (senderAvatarLabel != null || senderAvatar != null);

  const senderHalo = showSenderHalo ? (
    <Avatar
      label={senderAvatarLabel ?? undefined}
      size={32}
      online={!isSelf}
      imageUrl={senderAvatar || null}
      onClick={onSenderClick}
      ariaLabel={senderName ?? "发送者个人主页"}
    />
  ) : null;

  // 消息操作按钮（收藏/引用/撤回）：与气泡同一行 —— 别人的气泡右侧、自己的气泡左侧
  const actions = !recalled && message.type !== "system" ? (
    <div className="msg-actions">
      <FavoriteButton targetType="message" targetId={message.id} compact />
      {onQuote && (
        <button
          type="button"
          className="msg-action-btn"
          onClick={() => onQuote(message)}
          aria-label="引用回复"
        >
          <IconQuote width={12} height={12} style={{ verticalAlign: "-2px", marginRight: 4 }} />
          引用
        </button>
      )}
      {onRecall && (
        <button
          type="button"
          className="msg-action-btn"
          onClick={() => onRecall(message)}
          aria-label="撤回消息"
        >
          <IconUndo width={12} height={12} style={{ verticalAlign: "-2px", marginRight: 4 }} />
          撤回
        </button>
      )}
    </div>
  ) : null;

  // 单行布局（design.md §4）：统一 DOM = [头像][气泡][操作]；
  // peer 行 row 直排 = [头像][气泡][操作]；self 行 row-reverse 翻转 = [操作][气泡][头像]，
  // 自己的气泡整体居右、头像在最右。
  // 乐观发送状态（自己的气泡左侧同行）：上传中进度+可取消 / 纯文本 spinner / 失败重试删除
  const uploadProgress = message.pending ? (message.uploadProgress ?? null) : null;
  const uploading = uploadProgress != null;
  const sendState =
    isSelf && !recalled && (message.pending || message.sendFailed) ? (
      <div
        className="msg-send-state"
        data-state={message.sendFailed ? "failed" : uploading ? "uploading" : "sending"}
      >
        {message.pending ? (
          uploading ? (
            <>
              <span className="msg-send-progress" role="status">
                上传中 {Math.round(uploadProgress)}%
              </span>
              {onCancel && (
                <button
                  type="button"
                  className="msg-action-btn"
                  onClick={() => onCancel(message)}
                  aria-label="取消发送"
                >
                  取消
                </button>
              )}
            </>
          ) : (
            <span className="msg-send-spinner" role="status" aria-label="发送中" />
          )
        ) : (
          <>
            <span className="msg-send-failed-text" aria-label="发送失败">发送失败</span>
            {onRetry && (
              <button type="button" className="msg-action-btn" onClick={() => onRetry(message)} aria-label="重试发送">
                <IconUndo width={11} height={11} style={{ verticalAlign: "-2px", marginRight: 3 }} />
                重试
              </button>
            )}
            {onRemove && (
              <button type="button" className="msg-action-btn" onClick={() => onRemove(message)} aria-label="删除消息">
                <IconClose width={11} height={11} style={{ verticalAlign: "-2px", marginRight: 3 }} />
                删除
              </button>
            )}
          </>
        )}
      </div>
    ) : null;

  return (
    <div className={`msg-row ${isSelf ? "self" : "peer"}`}>
      {senderHalo}
      <div className="msg-body">
        {!isSelf && senderName && <span className="msg-sender">{senderName}</span>}
        {/* 发送状态放在 bubble 外层 wrapper：媒体气泡 .bubble-media 有 overflow:hidden，
            状态元素留在气泡内会被裁剪（上传进度/取消/失败按钮全部不可见） */}
        <div className="msg-bubble-wrap">
          {sendState}
          <div className={`${bubbleClass} ${isMedia && !recalled ? "bubble-media" : ""}`}>
            {quoteText != null && !recalled && (
              <div className="quote-strip" title={quoteText}>
                {quoteText}
              </div>
            )}
            {recalled ? (
              <span>{isSelf ? "你撤回了一条消息" : "对方撤回了一条消息"}</span>
            ) : message.type === "system" ? (
              <span>{message.content}</span>
            ) : isMedia ? (
              <MediaContent msg={message} />
            ) : (
              message.content || " "
            )}
            {/* 媒体消息气泡只渲染媒体本体：不显示 content 占位文案
               （「图片/语音」二字保留在会话列表预览与引用预览里） */}
          </div>
        </div>
        <div className="bubble-meta">
          <span className="bubble-time">{timeAgo(message.created_at)}</span>
          {/* 已读/未读回执标记不实现（产品决策）：消息状态仅内部流转，不在气泡展示 */}
        </div>
      </div>
      {actions}
    </div>
  );
}
