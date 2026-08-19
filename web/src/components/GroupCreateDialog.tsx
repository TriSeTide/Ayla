/**
 * GroupCreateDialog —— 创建群聊对话框（R-F3 最小集：群名必填 + 群头像可选后置）。
 *
 * 相比旧 ConversationSearch「先搜用户勾选再建群」，本对话框提供直接建群表单：
 * 1. 群名（必填）——填了即可建群，成员可选；
 * 2. 成员搜索（可选）——搜索用户，可勾选加入建群成员，也可直接点「私聊」发起会话；
 * 3. 建群按钮在群名非空时即可用（member_ids 可为空，后端 GroupCreateView 兼容空数组）。
 *
 * 建群成功跳 /group/:id；发起私聊跳 /chat/:id（复用原入口语义）。
 */
import { useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import { searchUsers } from "../api/users";
import type { UserPublic } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { IconClose, IconPlus, IconSearch } from "./icons";

export function GroupCreateDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const currentUser = useAuthStore((s) => s.currentUser);
  const upsertConversation = useChatStore((s) => s.upsertConversation);

  const [title, setTitle] = useState("");
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<UserPublic[]>([]);
  const [selected, setSelected] = useState<UserPublic[]>([]);
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
        setResults(list.filter((u) => u.id !== currentUser?.id));
      } catch {
        setResults([]);
      }
    }, 300);
  };

  // 勾选/取消成员（结果行是候选，已选进 selected 数组）
  const toggleMember = (u: UserPublic) => {
    setSelected((prev) =>
      prev.some((m) => m.id === u.id) ? prev.filter((m) => m.id !== u.id) : [...prev, u],
    );
  };

  const createGroup = async () => {
    if (!title.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const conv = await chatApi.createGroupConversation({
        title: title.trim(),
        member_ids: selected.map((m) => m.id),
      });
      // 立即更新会话列表，让左侧栏 ServerRail 显示新群
      upsertConversation(conv);
      onClose();
      navigate(`/group/${conv.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "建群失败");
    } finally {
      setBusy(false);
    }
  };

  const openPrivate = async (u: UserPublic) => {
    setBusy(true);
    setError(null);
    try {
      const conv = await chatApi.openPrivateConversation(u.id);
      // 立即更新会话列表，让私聊也能在会话列表中显示
      upsertConversation(conv);
      onClose();
      navigate(`/chat/${conv.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发起私聊失败");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="group-create-overlay" onClick={onClose}>
      <div
        className="group-create-dialog glass-card"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label="创建群聊"
      >
        <header className="group-create-dialog-head">
          <span className="group-create-dialog-title">创建群聊</span>
          <button type="button" className="icon-btn-40" onClick={onClose} aria-label="关闭">
            <IconClose width={18} height={18} />
          </button>
        </header>

        {/* 群名（必填） */}
        <input
          className="field"
          autoFocus
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="群名（必填）"
          aria-label="群名"
        />

        {/* 成员搜索（可选） */}
        <div className="group-create-search">
          <IconSearch width={15} height={15} className="group-create-search-icon" />
          <input
            className="field"
            value={query}
            onChange={(e) => doSearch(e.target.value)}
            placeholder="搜索成员（可选，可稍后在群内添加）"
            aria-label="搜索成员"
          />
        </div>

        {error && <div className="field-error">{error}</div>}

        {/* 已选成员 chips */}
        {selected.length > 0 && (
          <div className="group-create-chips" aria-label="已选成员">
            {selected.map((u) => (
              <span key={u.id} className="group-create-chip">
                {u.nickname || u.username}
                <button
                  type="button"
                  className="group-create-chip-x"
                  onClick={() => toggleMember(u)}
                  aria-label={`移除 ${u.nickname || u.username}`}
                >
                  <IconClose width={12} height={12} />
                </button>
              </span>
            ))}
          </div>
        )}

        {/* 搜索结果 */}
        {query.trim() && (
          <ul className="group-create-results">
            {results.map((u) => {
              const checked = selected.some((m) => m.id === u.id);
              return (
                <li key={u.id} className="group-create-result">
                  <label className="group-create-result-check">
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={() => toggleMember(u)}
                    />
                    <span className="group-create-result-name">{u.nickname || u.username}</span>
                  </label>
                  <button
                    type="button"
                    className="btn btn-ghost"
                    style={{ minHeight: 32, padding: "0 12px", fontSize: 12 }}
                    onClick={() => void openPrivate(u)}
                    disabled={busy}
                  >
                    私聊
                  </button>
                </li>
              );
            })}
            {results.length === 0 && <li className="search-empty">没有匹配的用户</li>}
          </ul>
        )}

        <button
          type="button"
          className="btn btn-primary group-create-submit"
          onClick={() => void createGroup()}
          disabled={busy || !title.trim()}
        >
          <IconPlus width={16} height={16} />
          建群{selected.length > 0 ? `（${selected.length} 人）` : ""}
        </button>
      </div>
    </div>
  );
}
