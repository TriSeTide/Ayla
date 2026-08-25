/**
 * SearchPage —— 全局搜索页（路由 /search，F9，R-S1~S4）。
 *
 * 顶栏复用窄屏 TopBar（variant="search"：自动聚焦 + 左返回 + 输入框，布局文档 §2.7），
 * 搜索词走 URL ?q=（与宽屏 TopNav 同一通道）；宽屏由 AppShell TopNav 承载搜索框。
 * 历史 chips（可清空）+ 五类分组结果（用户/群/帖子/直播间/桌游室）+
 * 每组截断 + "查看更多"；用户点击弹资料卡（加好友/发消息），其余跳对应界面。
 * 可见性过滤由后端完成，前端仅展示（R-S3）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { search } from "../api/search";
import { applyToGroup } from "../api/chat";
import type { SearchGroupItem, SearchResults, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { UserProfileCard } from "../components/UserProfileCard";
import { useSearchStore } from "../stores/search";
import { useChatStore } from "../stores/chat";
import { useAuthStore } from "../stores/auth";
import { goUserProfile } from "../utils/navigation";
import { chatWS } from "../ws/chat";
import type { ChatServerFrame } from "../api/types";

export function SearchPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const q = searchParams.get("q") ?? "";
  const { history, pushHistory, clearHistory } = useSearchStore();
  const conversations = useChatStore((state) => state.conversations);
  const joinedConversationIds = useMemo(
    () => new Set(conversations.filter((conversation) => conversation.type === "group").map((conversation) => conversation.id)),
    [conversations],
  );
  const [results, setResults] = useState<SearchResults | null>(null);
  // 审批通过事件与 group.joined 之间可能存在极短窗口，先显示“已通过”，
  // 随 group.joined 到达再由 chat store 确认“已加入”。
  const [acceptedGroupIds, setAcceptedGroupIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedUser, setSelectedUser] = useState<UserPublic | null>(null);
  const [selectedGroup, setSelectedGroup] = useState<SearchGroupItem | null>(null);
  const [joinMessage, setJoinMessage] = useState("");
  const [joinBusy, setJoinBusy] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const [joinSent, setJoinSent] = useState(false);
  const searchRequestRef = useRef(0);

  /** 公开群（join_policy=public）直接加入；缺失视为申请制（兼容旧数据），与后端默认一致 */
  const isPublicGroup = selectedGroup?.join_policy === "public";

  const openGroupApply = (group: SearchGroupItem) => {
    setSelectedGroup(group);
    setJoinMessage("");
    setJoinError(null);
    setJoinSent(false);
  };

  const closeGroupApply = () => {
    if (joinBusy) return;
    setSelectedGroup(null);
    setJoinError(null);
  };

  const submitGroupApply = async () => {
    if (!selectedGroup || joinBusy || joinSent) return;
    if (acceptedGroupIds.has(selectedGroup.id) || joinedConversationIds.has(selectedGroup.id)) {
      setSelectedGroup(null);
      return;
    }
    setJoinBusy(true);
    setJoinError(null);
    try {
      const response = await applyToGroup(selectedGroup.id, joinMessage.trim());
      if ("conversation_id" in response && response.status === "accepted") {
        setSelectedGroup(null);
        navigate("/group/" + response.conversation_id);
        return;
      }
      setJoinSent(true);
    } catch (e) {
      setJoinError(e instanceof Error ? e.message : "发送入群申请失败");
    } finally {
      setJoinBusy(false);
    }
  };

  const refreshSearch = useCallback((query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    const requestId = ++searchRequestRef.current;
    setLoading(true);
    setError(null);
    search({ q: trimmed, limit: 3 })
      .then((nextResults) => {
        if (requestId === searchRequestRef.current) setResults(nextResults);
      })
      .catch((e) => {
        if (requestId === searchRequestRef.current) setError(e instanceof Error ? e.message : "搜索失败");
      })
      .finally(() => {
        if (requestId === searchRequestRef.current) setLoading(false);
      });
  }, []);

  const doSearch = useCallback(
    (query: string) => {
      const trimmed = query.trim();
      if (!trimmed) return;
      pushHistory(trimmed);
      refreshSearch(trimmed);
    },
    [pushHistory, refreshSearch],
  );

  // 入群审批是用户级实时事件；搜索结果本身不是成员关系的权威来源。
  // 接到事件后立即重查，且由 chat store 的 group.joined 状态驱动按钮文案。
  useEffect(() => {
    const off = chatWS.onFrame((frame: ChatServerFrame) => {
      if (frame.type === "group.request.resolved") {
        if (frame.data.status === "accepted") {
          setAcceptedGroupIds((current) => new Set(current).add(frame.data.conversation_id));
        } else {
          setAcceptedGroupIds((current) => {
            const next = new Set(current);
            next.delete(frame.data.conversation_id);
            return next;
          });
        }
        if (q) refreshSearch(q);
      } else if (frame.type === "group.joined") {
        setAcceptedGroupIds((current) => {
          const next = new Set(current);
          next.delete(frame.conversation.id);
          return next;
        });
        if (q) refreshSearch(q);
      }
    });
    return off;
  }, [q, refreshSearch]);

  // 五类分组是否全空（决定无结果空态）
  const hasAnyResult = useCallback((r: SearchResults | null): boolean => {
    if (!r) return false;
    return [r.users, r.groups, r.posts, r.lives, r.games].some(
      (g) => (g?.total ?? 0) > 0,
    );
  }, []);

  // URL q 驱动：进入 /search?q=… 或顶栏/历史更新 q 时自动搜索
  useEffect(() => {
    if (!q) {
      setResults(null);
      setLoading(false);
      setError(null);
      return;
    }
    doSearch(q);
  }, [q, doSearch]);

  /** 历史 chips / 表单提交统一走 URL，与顶栏输入框同步 */
  const submitQuery = (query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    // replace：搜索词变更不进历史栈，返回键直接回上一个界面
    setSearchParams({ q: trimmed }, { replace: true });
  };

  return (
    <div className="search-page">
      {!q && history.length > 0 && (
        <div className="search-history">
          {history.map((h) => (
            <button key={h} type="button" className="search-chip" onClick={() => submitQuery(h)}>
              {h}
            </button>
          ))}
          <button type="button" className="search-clear" onClick={clearHistory}>
            清空
          </button>
        </div>
      )}

      {loading && <div className="search-loading">搜索中…</div>}
      {error && <p className="search-error">{error}</p>}

      {results && hasAnyResult(results) && (
        <div className="search-results">
          <ResultGroup
            title="用户"
            count={results.users?.total ?? 0}
            onMore={() => doSearch(q)}
          >
            {(results.users?.items ?? []).map((u) => (
              <button key={u.id} type="button" className="search-row" onClick={() => setSelectedUser(u)}>
                <Avatar
                  label={u.nickname || u.username}
                  size={36}
                  online={u.online}
                  imageUrl={u.avatar || null}
                  onClick={(e) => {
                    e.stopPropagation();
                    goUserProfile(useAuthStore.getState().currentUser?.id, u.id);
                  }}
                  ariaLabel={`查看 ${u.nickname || u.username} 的个人主页`}
                />
                <span className="search-row-title">{u.nickname || u.username}</span>
                {u.signature && <span className="search-row-sub">{u.signature}</span>}
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="群聊" count={results.groups?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.groups?.items ?? []).map((g) => {
              const joined = joinedConversationIds.has(g.id);
              const accepted = acceptedGroupIds.has(g.id);
              return (
                <button
                  key={g.id}
                  type="button"
                  className="search-row search-group-row"
                  onClick={() => {
                    if (joined) navigate(`/group/${g.id}`);
                    else if (!accepted) openGroupApply(g);
                  }}
                >
                  <span className="search-group-mark" aria-hidden="true">✦</span>
                  <span className="search-row-title">{g.title}</span>
                  <span className="search-row-action">{joined ? "已加入" : accepted ? "已通过" : "申请入群"}</span>
                </button>
              );
            })}
          </ResultGroup>

          <ResultGroup title="帖子" count={results.posts?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.posts?.items ?? []).map((p) => (
              <button key={p.id} type="button" className="search-row" onClick={() => navigate(`/posts/${p.id}`)}>
                <span className="search-row-title">{p.title || p.body.slice(0, 30)}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="直播间" count={results.lives?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.lives?.items ?? []).map((l) => (
              <button key={l.id} type="button" className="search-row" onClick={() => navigate(`/live/${l.id}`)}>
                <span className="search-row-title">{l.title}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="桌游室" count={results.games?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.games?.items ?? []).map((g) => (
              <button key={g.id} type="button" className="search-row" onClick={() => navigate("/games")}>
                <span className="search-row-title">{g.name}</span>
              </button>
            ))}
          </ResultGroup>
        </div>
      )}

      {results && !hasAnyResult(results) && !loading && !error && (
        <div className="search-empty" role="status">
          <h3 className="placeholder-title">未找到「{q}」相关结果</h3>
          <p className="placeholder-desc">换个关键词试试，或检查是否有拼写错误</p>
        </div>
      )}

      {selectedUser && (
        <div className="user-profile-overlay" onClick={() => setSelectedUser(null)}>
          <div onClick={(e) => e.stopPropagation()}>
            <UserProfileCard user={selectedUser} onClose={() => setSelectedUser(null)} />
          </div>
        </div>
      )}

      {selectedGroup && (
        <div className="group-apply-overlay" onClick={closeGroupApply}>
          <div className="group-apply-dialog glass-card" role="dialog" aria-modal="true" aria-labelledby="group-apply-title" onClick={(e) => e.stopPropagation()}>
            <header className="group-apply-head">
              <div>
                <span className="group-apply-kicker">GROUP REQUEST</span>
                <h2 id="group-apply-title">{isPublicGroup ? "加入" : "申请加入"}「{selectedGroup.title}」</h2>
              </div>
              <button type="button" className="icon-btn-40" onClick={closeGroupApply} aria-label="关闭">×</button>
            </header>
            {joinSent ? (
              <div className="group-apply-success" role="status">
                <span className="group-apply-success-icon" aria-hidden="true">✓</span>
                <strong>申请已发送</strong>
                <p>等待群主或管理员审核，同意后你就能进入群聊。</p>
                <button type="button" className="btn btn-primary" onClick={closeGroupApply}>知道了</button>
              </div>
            ) : (
              <>
                <p className="group-apply-desc">{isPublicGroup ? "这是一个公开群聊，点击即可直接加入。" : "这是一个申请制群聊，群主或管理员同意后才能入群。"}</p>
                <label className="group-apply-label" htmlFor="group-apply-message">给群主留言 <span>（可选）</span></label>
                <textarea id="group-apply-message" aria-label="给群主留言" className="field group-apply-message" value={joinMessage} maxLength={200} onChange={(e) => setJoinMessage(e.target.value)} placeholder="简单介绍一下自己吧…" />
                {joinError && <p className="group-apply-error" role="alert">{joinError}</p>}
                <div className="group-apply-actions">
                  <button type="button" className="btn btn-ghost" onClick={closeGroupApply} disabled={joinBusy}>取消</button>
                  <button type="button" className="btn btn-primary" onClick={() => void submitGroupApply()} disabled={joinBusy}>
                    {joinBusy ? (isPublicGroup ? "加入中…" : "发送中…") : (isPublicGroup ? "直接加入" : "发送入群申请")}
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function ResultGroup({ title, count, children, onMore }: {
  title: string;
  count: number;
  children: React.ReactNode;
  onMore?: () => void;
}) {
  if (count === 0) return null;
  return (
    <section className="search-group">
      <header className="search-group-head">
        <span className="search-group-title">{title}</span>
        {onMore && count > 3 && <button type="button" className="search-more" onClick={onMore}>查看更多</button>}
      </header>
      <div className="search-group-body">{children}</div>
    </section>
  );
}
