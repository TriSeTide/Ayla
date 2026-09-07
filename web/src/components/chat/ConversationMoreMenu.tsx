/**
 * ConversationMoreMenu —— 会话行「⋯ 更多」按钮 + 弹出菜单（置顶/取消置顶、可选删除）。
 *
 * 会话列表（ConversationList）、群卡片/群列表（GroupCard/GroupListItem）共用。
 * - 置顶/取消置顶：调 POST /conversations/<id>/pin/，成功后更新 chat store；
 * - 删除（仅 showDelete=true 时，消息列表私信用）：confirm 确认后调 POST
 *   /conversations/<id>/hide/（软删除），移除本人列表；群聊场景不提供删除（需求）；
 * - 菜单 portal 到 body，按触发按钮和视口空间选择上下位置；
 * - 外点/滚动关闭，Esc 返回触发按钮，方向键在菜单项间移动。
 */
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
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
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const initialFocus = useRef<"first" | "last">("first");
  const menuId = useId();
  const [position, setPosition] = useState({ left: 0, top: 0 });
  const closeMenu = useCallback((restoreFocus = false) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  }, []);

  useLayoutEffect(() => {
    if (!open) return;
    const positionMenu = () => {
      const anchor = triggerRef.current?.getBoundingClientRect();
      const menu = menuRef.current;
      if (!anchor || !menu) return;
      const box = menu.getBoundingClientRect();
      const gap = 6, edge = 8;
      const below = anchor.bottom + gap;
      const above = anchor.top - gap - box.height;
      const top = below + box.height <= window.innerHeight - edge ? below : above;
      setPosition({
        left: Math.max(edge, Math.min(anchor.right - box.width, window.innerWidth - box.width - edge)),
        top: Math.max(edge, Math.min(top, window.innerHeight - box.height - edge)),
      });
    };
    positionMenu();
    const items = menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)');
    items?.[initialFocus.current === "last" ? items.length - 1 : 0]?.focus();
    window.addEventListener("resize", positionMenu);
    return () => window.removeEventListener("resize", positionMenu);
  }, [open, showDelete]);

  // Portal nodes are outside the trigger subtree; both boundaries participate.
  useEffect(() => {
    if (!open) return;
    const onDocClick = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!ref.current?.contains(target) && !menuRef.current?.contains(target)) closeMenu();
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        closeMenu(true);
      }
    };
    const onScroll = (event: Event) => {
      if (!menuRef.current?.contains(event.target as Node)) closeMenu();
    };
    document.addEventListener("pointerdown", onDocClick);
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("scroll", onScroll, true);
    return () => {
      document.removeEventListener("pointerdown", onDocClick);
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("scroll", onScroll, true);
    };
  }, [open, closeMenu]);

  const reportError = (message: string) => {
    if (onError) onError(message);
    else alert(message);
  };

  const handleTogglePin = () => {
    if (busy) return;
    const next = !conversation.is_pinned;
    setBusy(true);
    closeMenu(true);
    chatApi
      .togglePinConversation(conversation.id, next)
      .then(() => useChatStore.getState().setPin(conversation.id, next))
      .catch((e) => reportError(e instanceof Error ? e.message : "置顶操作失败"))
      .finally(() => setBusy(false));
  };

  const handleDelete = () => {
    closeMenu();
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
    <div className="conv-more" ref={ref} onClick={(event) => event.stopPropagation()}>
      <button
        ref={triggerRef}
        type="button"
        className="conv-more-btn"
        aria-label={`${conversation.title} 的更多操作`}
        aria-expanded={open}
        aria-haspopup="menu"
        aria-controls={open ? menuId : undefined}
        disabled={busy}
        onClick={(e) => {
          e.stopPropagation();
          initialFocus.current = "first";
          setOpen(!open);
        }}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            initialFocus.current = event.key === "ArrowUp" ? "last" : "first";
            setOpen(true);
          }
        }}
      >
        <IconDots width={18} height={18} />
      </button>
      {open && createPortal(
        <div ref={menuRef} id={menuId} className="conv-menu" role="menu" aria-label={`${conversation.title} 操作菜单`}
          style={position}
          onClick={(event) => event.stopPropagation()}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault();
              event.stopPropagation();
              closeMenu(true);
              return;
            }
            const items = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)') ?? [])];
            if (event.key === "Tab") { closeMenu(true); return; }
            if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key) || !items.length) return;
            event.preventDefault();
            const index = items.indexOf(document.activeElement as HTMLButtonElement);
            const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1
              : (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
            items[next]?.focus();
          }}>
          <button
            type="button"
            className="conv-menu-item"
            role="menuitem"
            tabIndex={-1}
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
              tabIndex={-1}
              disabled={busy}
              onClick={handleDelete}
            >
              <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
                <path d="M6 7h12l-1 13H7L6 7zm3-3h6l1 2H8l1-2z" fill="currentColor" />
              </svg>
              删除会话
            </button>
          )}
        </div>, document.body,
      )}
      {confirmDeleteOpen && (
        <ConfirmDialog
          title="删除会话"
          message={`删除会话「${conversation.title}」？\n消息记录会保留，对方再发消息时会话将重新出现。`}
          onConfirm={doDelete}
          onClose={() => { setConfirmDeleteOpen(false); triggerRef.current?.focus(); }}
        />
      )}
    </div>
  );
}
