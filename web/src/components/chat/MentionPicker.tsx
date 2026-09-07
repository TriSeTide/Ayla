/**
 * MentionPicker —— 群聊 @ 成员选择器（M8 @ 能力，仅群聊）。
 *
 * 输入框输入 @ 后弹出：玻璃浮层 + 搜索过滤（@ 后继续输入即实时过滤）+ 头像 + 昵称。
 * 选中 → 生成不可拆分 @Token（由 MessageInput 插入编辑器）。
 *
 * 群成员按服务端 query + cursor 分页；服务端排除自己，旧内联成员参数仅供有限数据兼容。
 * 视觉：design.md §12.8.1 弹层规格（玻璃 + blur + 圆角）；头像复用 Avatar（无 onClick，
 * 避免 button 嵌套 button 的可访问性违规）。
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import type { ConversationMember } from "../../api/types";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { Avatar } from "../Avatar";
import { useSocialPage } from "../../hooks/useSocialPage";
import { DirectoryLoadMore } from "../DirectoryLoadMore";

export function MentionPicker({
  members,
  groupId,
  query,
  onSelect,
  anchorRef,
  onClose,
}: {
  members: ConversationMember[];
  groupId?: string;
  /** @ 之后的过滤词（不含 @；空 = 显示全部成员） */
  query: string;
  onSelect: (member: ConversationMember) => void;
  /** Editor anchor; the floating layer escapes the composer's backdrop root. */
  anchorRef?: RefObject<HTMLElement>;
  onClose?: () => void;
}) {
  const pickerRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: 8, top: 8, width: 280, maxHeight: 280 });
  const currentUserId = useAuthStore((s) => s.currentUser?.id ?? null);
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  const q = query.trim().toLowerCase();
  const memberPage = useSocialPage("members", { groupId, q: query, excludeSelf: true }, !!groupId);
  const visibleMembers = groupId ? memberPage.items : members;

  const filtered = useMemo(() => {
    return visibleMembers.filter((m) => {
      if (currentUserId && m.user.id === currentUserId) return false; // 排除自己
      if (!q) return true;
      // 同时匹配昵称与用户名（nickname 优先展示，username 仍可检索）
      const haystack = `${m.user.nickname || ""} ${m.user.username || ""}`.toLowerCase();
      return haystack.includes(q);
    });
  }, [visibleMembers, q, currentUserId]);

  useLayoutEffect(() => {
    if (!anchorRef) return;
    const update = () => {
      const anchor = anchorRef.current?.closest(".composer") ?? anchorRef.current;
      const picker = pickerRef.current;
      if (!anchor || !picker) return;
      const rect = anchor.getBoundingClientRect();
      const edge = 8, gap = 8;
      const height = Math.min(280, picker.scrollHeight + 2);
      const above = rect.top - gap - edge;
      const below = window.innerHeight - rect.bottom - gap - edge;
      const placeAbove = above >= height || above >= below;
      const maxHeight = Math.max(40, Math.min(280, placeAbove ? above : below));
      const width = Math.max(0, Math.min(rect.width, window.innerWidth - edge * 2));
      setPosition({
        left: Math.max(edge, Math.min(rect.left, window.innerWidth - width - edge)),
        top: Math.max(edge, placeAbove ? rect.top - gap - Math.min(height, maxHeight) : rect.bottom + gap),
        width, maxHeight,
      });
    };
    update();
    window.addEventListener("resize", update);
    document.addEventListener("scroll", update, true);
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);
    if (anchorRef.current) observer?.observe(anchorRef.current);
    return () => {
      window.removeEventListener("resize", update);
      document.removeEventListener("scroll", update, true);
      observer?.disconnect();
    };
  }, [anchorRef, filtered.length, memberPage.loading, memberPage.error]);

  useEffect(() => {
    if (!anchorRef) return;
    const onOutside = (event: PointerEvent) => {
      if (!pickerRef.current?.contains(event.target as Node) && !anchorRef.current?.contains(event.target as Node)) onClose?.();
    };
    const onKey = (event: KeyboardEvent) => {
      const inPicker = pickerRef.current?.contains(event.target as Node);
      if (!inPicker && !anchorRef.current?.contains(event.target as Node)) return;
      if (event.key === "Escape") {
        event.preventDefault();
        onClose?.();
        anchorRef.current?.focus({ preventScroll: true });
      } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        const options = [...(pickerRef.current?.querySelectorAll<HTMLButtonElement>('[role="option"]') ?? [])];
        if (!options.length) return;
        event.preventDefault();
        const current = options.indexOf(document.activeElement as HTMLButtonElement);
        const index = current < 0 ? event.key === "ArrowDown" ? 0 : options.length - 1
          : (current + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length;
        options[index]?.focus();
      }
    };
    document.addEventListener("pointerdown", onOutside);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onOutside);
      document.removeEventListener("keydown", onKey);
    };
  }, [anchorRef, onClose]);

  const picker = (
    <div ref={pickerRef} className={`mention-picker${anchorRef ? " is-portal" : ""}`} style={anchorRef ? position : undefined} role="listbox" aria-label="选择要 @ 的成员">
      <div className="mention-picker-scroll" style={anchorRef ? { maxHeight: position.maxHeight - 2 } : undefined} onScroll={(event) => { if (groupId) memberPage.onScroll(event.currentTarget); }}>
        {filtered.map((m) => {
          const name = m.user.nickname || m.user.username;
          return (
            <button
              key={m.user.id}
              type="button"
              role="option"
              className="mention-picker-item"
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => onSelect(m)}
              aria-label={`@${name}`}
            >
              <Avatar
                label={name}
                size={32}
                online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, m.user))}
                imageUrl={m.user.avatar || null}
              />
              <span className="mention-picker-name">{name}</span>
            </button>
          );
        })}
        {filtered.length === 0 && !memberPage.loading && !memberPage.error && <div className="mention-picker-empty">无匹配成员</div>}
        {groupId && <DirectoryLoadMore {...memberPage} retainCompletedSpace={false} />}
      </div>
    </div>
  );
  return anchorRef ? createPortal(picker, document.body) : picker;
}
