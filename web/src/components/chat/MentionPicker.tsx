/**
 * MentionPicker —— 群聊 @ 成员选择器（M8 @ 能力，仅群聊）。
 *
 * 输入框输入 @ 后弹出：玻璃浮层 + 搜索过滤（@ 后继续输入即实时过滤）+ 头像 + 昵称。
 * 选中 → 生成不可拆分 @Token（由 MessageInput 插入编辑器）。
 *
 * 数据源：conversation.members（全量，前端本地过滤）；排除当前用户自己（@ 自己无意义）。
 * 视觉：design.md §12.8.1 弹层规格（玻璃 + blur + 圆角）；头像复用 Avatar（无 onClick，
 * 避免 button 嵌套 button 的可访问性违规）。
 */
import { useMemo } from "react";
import type { ConversationMember } from "../../api/types";
import { useAuthStore } from "../../stores/auth";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { Avatar } from "../Avatar";

export function MentionPicker({
  members,
  query,
  onSelect,
}: {
  members: ConversationMember[];
  /** @ 之后的过滤词（不含 @；空 = 显示全部成员） */
  query: string;
  onSelect: (member: ConversationMember) => void;
}) {
  const currentUserId = useAuthStore((s) => s.currentUser?.id ?? null);
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  const q = query.trim().toLowerCase();

  const filtered = useMemo(() => {
    return members.filter((m) => {
      if (currentUserId && m.user.id === currentUserId) return false; // 排除自己
      if (!q) return true;
      // 同时匹配昵称与用户名（nickname 优先展示，username 仍可检索）
      const haystack = `${m.user.nickname || ""} ${m.user.username || ""}`.toLowerCase();
      return haystack.includes(q);
    });
  }, [members, q, currentUserId]);

  return (
    <div className="mention-picker" role="listbox" aria-label="选择要 @ 的成员">
      <div className="mention-picker-scroll">
        {filtered.map((m) => {
          const name = m.user.nickname || m.user.username;
          return (
            <button
              key={m.user.id}
              type="button"
              role="option"
              className="mention-picker-item"
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
        {filtered.length === 0 && <div className="mention-picker-empty">无匹配成员</div>}
      </div>
    </div>
  );
}
