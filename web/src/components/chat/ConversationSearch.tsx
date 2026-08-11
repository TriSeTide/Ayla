/**
 * ConversationSearch：搜索用户 → 发起私聊 / 建群（文档 §3.4 / §2 components/chat/ConversationSearch.tsx）。
 *
 * - 输入关键词搜索用户（GET /users/search/?q=）；
 * - 点击用户 → 发起私聊（POST /conversations/private/ {user_id}）；
 * - 勾选多人 + 输入群名 → 建群（POST /conversations/ {title, member_ids[]}）。
 */
import { useRef, useState } from "react";
import * as chatApi from "../../api/chat";
import { searchUsers } from "../../api/users";
import type { UserPublic } from "../../api/types";

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
      <button className="conv-search-toggle" onClick={() => setOpen(true)}>
        ＋ 新会话
      </button>
    );
  }

  return (
    <div className="conv-search">
      <div className="conv-search-head">
        <strong>发起会话</strong>
        <button className="conv-search-close" onClick={reset}>
          ×
        </button>
      </div>
      <input
        autoFocus
        value={query}
        onChange={(e) => doSearch(e.target.value)}
        placeholder="搜索用户名 / 昵称"
      />
      {error && <div className="send-error">{error}</div>}
      <ul className="search-results">
        {results.map((u) => (
          <li key={u.id} className="search-row">
            <span className="search-user">
              <span className="avatar">{u.nickname?.[0] ?? u.username[0]}</span>
              {u.nickname || u.username}
            </span>
            <label className="search-actions">
              <button onClick={() => void openPrivate(u)} disabled={busy}>
                私聊
              </button>
              <input
                type="checkbox"
                checked={selected.includes(u.id)}
                onChange={(e) =>
                  setSelected((prev) =>
                    e.target.checked ? [...prev, u.id] : prev.filter((id) => id !== u.id),
                  )
                }
                title="勾选以加入新群"
              />
            </label>
          </li>
        ))}
        {query.trim() && results.length === 0 && (
          <li className="search-empty">没有匹配的用户</li>
        )}
      </ul>
      {selected.length > 0 && (
        <div className="group-create">
          <input
            value={groupTitle}
            onChange={(e) => setGroupTitle(e.target.value)}
            placeholder="群名（创建群聊）"
          />
          <button onClick={() => void createGroup()} disabled={busy || !groupTitle.trim()}>
            建群（{selected.length} 人）
          </button>
        </div>
      )}
    </div>
  );
}
