/**
 * ConversationMoreMenu —— 会话行「⋯ 更多」按钮 + 弹出菜单（置顶/取消置顶、可选删除）。
 *
 * 会话列表（ConversationList）、群卡片/群列表（GroupCard/GroupListItem）共用。
 * - 置顶/取消置顶：调 POST /conversations/<id>/pin/，成功后更新 chat store；
 * - 删除（仅 showDelete=true 时，消息列表私信用）：confirm 确认后调 POST
 *   /conversations/<id>/hide/（软删除），移除本人列表；群聊场景不提供删除（需求）；
 * - 菜单向上展开 + z-index 60（不被滚动容器裁剪、不被固定栏遮挡）；
 * - 点击菜单外部关闭。
 */
import { useEffect, useRef, useState } from "react";
import * as chatApi from "../../api/chat";
import { useChatStore } from "../../stores/chat";
import { ConfirmDialog } from "../ConfirmDialog";
import { IconPin, IconDots } from "../icons";

export function ConversationMoreMenu({
  conversation,
  showDelete = true,
  onError,
}: {
  /** 会话（群聊/私聊均可；is_pinned 用于菜单文案） */
  conversation: { id: string; title: string; is_pinned?: boolean };
  /** 是否提供「删除会话」项（群聊不提供，需求；私信保留） */
  showDelete?: boolean;
  /** 操作失败提示（父组件错误条）；缺省时用 alert 兜底 */
  onError?: (message: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  // 点击菜单外部 → 关闭
  useEffect(() => {
    if (!open) return;
    const onDocClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, [open]);

  const reportError = (message: string) => {
    if (onError) onError(message);
    else alert(message);
  };

  const handleTogglePin = () => {
    const next = !conversation.is_pinned;
    setBusy(true);
    setOpen(false);
    chatApi
      .togglePinConversation(conversation.id, next)
      .then(() => useChatStore.getState().setPin(conversation.id, next))
      .catch((e) => reportError(e instanceof Error ? e.message : "置顶操作失败"))
      .finally(() => setBusy(false));
  };

  const handleDelete = () => {
    setOpen(false);
    setConfirmDeleteOpen(true);
  };

  const doDelete = () => {
    setConfirmDeleteOpen(false);
    setBusy(true);
    chatApi
      .hideConversation(conversation.id)
      .then(() => useChatStore.getState().removeConversation(conversation.id))
      .catch((e) => reportError(e instanceof Error ? e.message : "删除会话失败"))
      .finally(() => setBusy(false));
  };

  return (
    <div className="conv-more" ref={ref}>
      <button
        type="button"
        className="conv-more-btn"
        aria-label={`${conversation.title} 的更多操作`}
        aria-expanded={open}
        onClick={(e) => {
          e.stopPropagation();
          setOpen(!open);
        }}
      >
        <IconDots width={18} height={18} />
      </button>
      {open && (
        <div className="conv-menu" role="menu" aria-label={`${conversation.title} 操作菜单`}>
          <button
            type="button"
            className="conv-menu-item"
            role="menuitem"
            disabled={busy}
            onClick={handleTogglePin}
          >
            <IconPin width={16} height={16} />
            {conversation.is_pinned ? "取消置顶" : "置顶"}
          </button>
          {showDelete && (
            <button
              type="button"
              className="conv-menu-item conv-menu-item-danger"
              role="menuitem"
              disabled={busy}
              onClick={handleDelete}
            >
              <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
                <path d="M6 7h12l-1 13H7L6 7zm3-3h6l1 2H8l1-2z" fill="currentColor" />
              </svg>
              删除会话
            </button>
          )}
        </div>
      )}
      {confirmDeleteOpen && (
        <ConfirmDialog
          title="删除会话"
          message={`删除会话「${conversation.title}」？\n消息记录会保留，对方再发消息时会话将重新出现。`}
          onConfirm={doDelete}
          onClose={() => setConfirmDeleteOpen(false)}
        />
      )}
    </div>
  );
}
