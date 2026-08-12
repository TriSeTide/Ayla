/**
 * ConversationSearch —— 搜索用户 → 发起私聊 / 勾选多人建群。
 * 逻辑不变（GET /users/search/、POST /conversations/private/、POST /conversations/），
 * 视觉按 design.md 玻璃面板 + 字段错误就近展示。
 */
import { useRef, useState } from "react";
import * as chatApi from "../../api/chat";
import { searchUsers } from "../../api/users";
import type { UserPublic } from "../../api/types";
import { IconClose, IconPlus } from "../icons";

export function ConversationSearch({
  currentUserId,
  onPrivateOpened,
  onGroupCreated,
}: {
  currentUserId: string | null;
  onPrivateOpened: (convId: string) => void;
  onGroupCreated: (convId: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<UserPublic[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [groupTitle, setGroupTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const doSearch = (q: string) => {
    setQuery(q);
    if (timerRef.current) clearTimeout(timerRef.current);
    if (!q.trim()) {
      setResults([]);
      return;
    }
    timerRef.current = setTimeout(async () => {
      try {
        const list = await searchUsers(q.trim());
        setResults(list.filter((u) => u.id !== currentUserId));
      } catch {
        setResults([]);
      }
    }, 300);
  };

  const openPrivate = async (user: UserPublic) => {
    setBusy(true);
    setError(null);
    try {
      const conv = await chatApi.openPrivateConversation(user.id);
      onPrivateOpened(conv.id);
      reset();
    } catch (e) {
      setError(e instanceof Error ? e.message : "发起私聊失败");
    } finally {
      setBusy(false);
    }
  };

  const createGroup = async () => {
    if (!groupTitle.trim() || selected.length === 0) return;
    setBusy(true);
    setError(null);
    try {
      const conv = await chatApi.createGroupConversation({
        title: groupTitle.trim(),
        member_ids: selected,
      });
      onGroupCreated(conv.id);
      reset();
    } catch (e) {
      setError(e instanceof Error ? e.message : "建群失败");
    } finally {
      setBusy(false);
    }
  };

  const reset = () => {
    setOpen(false);
    setQuery("");
    setResults([]);
    setSelected([]);
    setGroupTitle("");
    setError(null);
  };

  if (!open) {
    return (
      <button type="button" className="btn btn-ghost conv-new-btn" onClick={() => setOpen(true)}>
        <IconPlus width={15} height={15} />
        新会话
      </button>
    );
  }

  return (
    <div className="glass-card conv-search-panel">
      <div className="chat-sidebar-head">
        <strong style={{ fontSize: 14 }}>发起会话</strong>
        <button type="button" className="quote-bar-cancel" onClick={reset} aria-label="关闭">
          <IconClose width={14} height={14} />
        </button>
      </div>
      <input
        className="field"
        autoFocus
        value={query}
        onChange={(e) => doSearch(e.target.value)}
        placeholder="搜索用户名 / 昵称"
      />
      {error && <div className="field-error">{error}</div>}
      <ul>
        {results.map((u) => (
          <li key={u.id} className="search-result-row">
            <span className="search-result-name">{u.nickname || u.username}</span>
            <span className="search-result-actions">
              <button
                type="button"
                className="btn btn-ghost"
                style={{ minHeight: 32, padding: "0 12px", fontSize: 12 }}
                onClick={() => void openPrivate(u)}
                disabled={busy}
              >
                私聊
              </button>
              <label style={{ display: "flex", alignItems: "center", gap: 4, cursor: "pointer" }}>
                <input
                  type="checkbox"
                  checked={selected.includes(u.id)}
                  onChange={(e) =>
                    setSelected((prev) =>
                      e.target.checked ? [...prev, u.id] : prev.filter((id) => id !== u.id),
                    )
                  }
                />
                入群
              </label>
            </span>
          </li>
        ))}
        {query.trim() && results.length === 0 && <li className="search-empty">没有匹配的用户</li>}
      </ul>
      {selected.length > 0 && (
        <div className="group-create">
          <input
            className="field"
            value={groupTitle}
            onChange={(e) => setGroupTitle(e.target.value)}
            placeholder="群名"
          />
          <button
            type="button"
            className="btn btn-primary"
            style={{ flexShrink: 0 }}
            onClick={() => void createGroup()}
            disabled={busy || !groupTitle.trim()}
          >
            建群（{selected.length}）
          </button>
        </div>
      )}
    </div>
  );
}
