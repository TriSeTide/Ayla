/**
 * SearchPage —— 全局搜索页（路由 /search，F9，R-S1~S4）。
 *
 * 顶栏复用窄屏 TopBar（variant="search"：自动聚焦 + 左返回 + 输入框，布局文档 §2.7），
 * 搜索词走 URL ?q=（与宽屏 TopNav 同一通道）；宽屏由 AppShell TopNav 承载搜索框。
 * 历史 chips（可清空）+ 五类分组结果（用户/群/帖子/直播间/桌游室）+
 * 每组独立游标续页；用户点击弹资料卡（加好友/发消息），其余跳对应界面。
 * 可见性过滤由后端完成，前端仅展示（R-S3）。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { searchPages, type SearchPageResults, type SearchType } from "../api/search";
import { applyToGroup } from "../api/chat";
import type { SearchGroupItem, SearchResults, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { UserProfileCard } from "../components/UserProfileCard";
import { useSearchStore } from "../stores/search";
import { useChatStore } from "../stores/chat";
import { useAuthStore } from "../stores/auth";
import { usePresenceStore } from "../stores/presence";
import { presenceOnline, withLiveStatus } from "../utils/displayStatus";
import { goUserProfile } from "../utils/navigation";
import { chatWS } from "../ws/chat";
import type { ChatServerFrame } from "../api/types";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { StablePaginationFooter } from "../components/StablePaginationFooter";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";

type ResultKey = keyof SearchResults;
const RESULT_TYPES: Record<ResultKey, SearchType> = { users: "user", groups: "group", posts: "post", lives: "live", games: "game" };
const RESULT_KEYS: Record<SearchType, ResultKey> = { user: "users", group: "groups", post: "posts", live: "lives", game: "games" };
type SearchFilter = SearchType | "all";
const FILTERS: ReadonlyArray<{ key: SearchFilter; label: string }> = [
  { key: "all", label: "全部" },
  { key: "user", label: "用户" },
  { key: "group", label: "群聊" },
  { key: "post", label: "帖子" },
  { key: "live", label: "直播间" },
  { key: "game", label: "桌游室" },
];
type PageStatus = Partial<Record<ResultKey, { loading: boolean; error: string | null }>>;
const searchPageMemory = new Map<string, { results: SearchPageResults; updatedAt: number; stale: boolean }>();
let searchSession = 0;
useAuthStore.subscribe((state, previous) => {
  if (state.currentUser?.id !== previous.currentUser?.id || Boolean(state.accessToken) !== Boolean(previous.accessToken)) {
    searchSession += 1;
    searchPageMemory.clear();
  }
});
export function clearSearchPageMemory() { searchPageMemory.clear(); }
function searchAccount() { return `${useAuthStore.getState().currentUser?.id ?? "anonymous"}:${searchSession}`; }
function searchScope(query: string, filter: SearchFilter) { return JSON.stringify([searchAccount(), query.trim(), filter]); }
function invalidateSearchPages() {
  // Authentication changes clear this map, so every entry belongs to the current reader.
  for (const [key, cached] of searchPageMemory) searchPageMemory.set(key, { ...cached, stale: true });
}

export function SearchPage() {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const q = searchParams.get("q") ?? "";
  const filter = FILTERS.find((item) => item.key === searchParams.get("type"))?.key ?? "all";
  const filterId = useId();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${Boolean(state.accessToken)}`);
  const scope = searchScope(q, filter);
  const activeScope = useRef(scope);
  activeScope.current = scope;
  const { history, pushHistory, clearHistory } = useSearchStore();
  const conversations = useChatStore((state) => state.conversations);
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  const joinedConversationIds = useMemo(
    () => new Set(conversations.filter((conversation) => conversation.type === "group").map((conversation) => conversation.id)),
    [conversations],
  );
  const [resultData, setResultData] = useState<SearchPageResults | null>(null);
  const [resultScope, setResultScope] = useState(scope);
  const scopedResults = resultScope === scope ? resultData : null;
  const resultKey = filter === "all" ? null : RESULT_KEYS[filter];
  const results: SearchPageResults | null = scopedResults && resultKey
    ? { [resultKey]: scopedResults[resultKey] } : scopedResults;
  const resultRef = useRef<SearchPageResults | null>(null);
  const [pageStatus, setPageStatus] = useState<PageStatus>({});
  const [stale, setStale] = useState(false);
  const [resumeEntry, setResumeEntry] = useState(false);
  const restoredScope = useRef<string | null>(null);
  const appendRequests = useRef(new Set<ResultKey>());
  const membershipChanges = useRef(new Map<string, { member: boolean; revision: number }>());
  const membershipRevision = useRef(0);
  const active = useRef(false);
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
  const pageRef = useRef<HTMLDivElement>(null);
  const { restoring } = useScrollRestore(scope, pageRef, { ready: results != null });
  useListEntryMotion(pageRef, ".search-row, .search-group .stable-pagination-footer .btn", (restoring || restoredScope.current === scope) && !resumeEntry);
  const openPath = (path: string) => {
    saveScrollPosition(scope, pageRef.current);
    navigate(path);
  };

  const commitResults = useCallback((next: SearchPageResults, key: string, updatedAt = Date.now(), isStale = searchPageMemory.get(key)?.stale ?? false) => {
    resultRef.current = next;
    setResultData(next);
    setResultScope(key);
    searchPageMemory.delete(key);
    searchPageMemory.set(key, { results: next, updatedAt, stale: isStale });
    while (searchPageMemory.size > 12) searchPageMemory.delete(searchPageMemory.keys().next().value!);
  }, []);

  const withCurrentMembership = useCallback((response: SearchPageResults, startedAt: number): SearchPageResults => {
    if (!response.groups) return response;
    return { ...response, groups: { ...response.groups, items: response.groups.items.map((group) => {
      const changed = membershipChanges.current.get(group.id);
      if (changed && changed.revision > startedAt) return { ...group, is_member: changed.member };
      if (group.is_member !== undefined) membershipChanges.current.delete(group.id);
      return group;
    }) } };
  }, []);

  const groupIsJoined = (group: SearchGroupItem) =>
    membershipChanges.current.get(group.id)?.member
    ?? resultRef.current?.groups?.items.find((item) => item.id === group.id)?.is_member
    ?? group.is_member
    ?? joinedConversationIds.has(group.id);

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
    if (acceptedGroupIds.has(selectedGroup.id) || groupIsJoined(selectedGroup)) {
      setSelectedGroup(null);
      return;
    }
    const actionScope = scope;
    setJoinBusy(true);
    setJoinError(null);
    try {
      const response = await applyToGroup(selectedGroup.id, joinMessage.trim());
      if (!active.current || activeScope.current !== actionScope || searchScope(q, filter) !== actionScope) return;
      if ("conversation_id" in response && response.status === "accepted") {
        setSelectedGroup(null);
        openPath("/group/" + response.conversation_id);
        return;
      }
      setJoinSent(true);
    } catch (e) {
      if (active.current && activeScope.current === actionScope) setJoinError(e instanceof Error ? e.message : "发送入群申请失败");
    } finally {
      if (active.current && activeScope.current === actionScope) setJoinBusy(false);
    }
  };

  const refreshSearch = useCallback((query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    const key = searchScope(trimmed, filter);
    const membershipAtStart = membershipRevision.current;
    const replacingVisible = resultRef.current != null && activeScope.current === key;
    const requestId = ++searchRequestRef.current;
    appendRequests.current.clear();
    setPageStatus({});
    setLoading(true);
    setError(null);
    const isCurrent = () => active.current && requestId === searchRequestRef.current
      && activeScope.current === key && searchScope(trimmed, filter) === key;
    searchPages(filter === "all" ? { q: trimmed, limit: 3 } : { q: trimmed, types: [filter], limit: 20 })
      .then((nextResults) => {
        if (!isCurrent()) return;
        if (filter !== "all" && !nextResults[RESULT_KEYS[filter]]) throw new Error("搜索分类结果缺失，请重试");
        for (const group of Object.values(nextResults)) {
          if (group?.has_more && !group.next_cursor) throw new Error("搜索续页游标缺失，请重试");
        }
        const membershipChangedDuringRequest = membershipRevision.current > membershipAtStart;
        commitResults(withCurrentMembership(nextResults, membershipAtStart), key, Date.now(), membershipChangedDuringRequest);
        if (replacingVisible) setResumeEntry(true);
        setStale(membershipChangedDuringRequest);
      })
      .catch((e) => {
        if (isCurrent()) setError(e instanceof Error ? e.message : "搜索失败");
      })
      .finally(() => {
        if (isCurrent()) setLoading(false);
      });
  }, [commitResults, filter, withCurrentMembership]);

  const loadMore = useCallback(async (type: ResultKey) => {
    const key = activeScope.current;
    const group = resultRef.current?.[type];
    if (!active.current || appendRequests.current.has(type) || !group?.has_more) return;
    const requestId = searchRequestRef.current;
    const membershipAtStart = membershipRevision.current;
    const cursor = group.next_cursor;
    appendRequests.current.add(type);
    setPageStatus((value) => ({ ...value, [type]: { loading: true, error: null } }));
    const isCurrent = () => active.current && requestId === searchRequestRef.current
      && activeScope.current === key && searchScope(q, filter) === key;
    try {
      if (!cursor) throw new Error("下一页游标缺失，请重新搜索");
      const response = await searchPages({ q: q.trim(), types: [RESULT_TYPES[type]], limit: 20, cursor });
      if (!isCurrent()) return;
      const incoming = withCurrentMembership(response, membershipAtStart)[type];
      if (!incoming || (incoming.has_more && (!incoming.next_cursor || incoming.next_cursor === cursor))) {
        throw new Error("搜索续页未推进，请重试或重新搜索");
      }
      const old = resultRef.current?.[type];
      const rows = new Map((old?.items ?? []).map((item) => [String(item.id), item]));
      for (const item of incoming.items) rows.set(String(item.id), item);
      commitResults({ ...resultRef.current, [type]: { ...incoming, items: [...rows.values()] } }, key);
      setResumeEntry(true);
    } catch (failure) {
      if (isCurrent()) setPageStatus((value) => ({ ...value, [type]: { loading: false, error: failure instanceof Error ? failure.message : "加载更多失败" } }));
    } finally {
      if (isCurrent()) {
        appendRequests.current.delete(type);
        setPageStatus((value) => ({ ...value, [type]: { loading: false, error: value[type]?.error ?? null } }));
      }
    }
  }, [commitResults, filter, q, withCurrentMembership]);

  const doSearch = useCallback(
    (query: string) => {
      const trimmed = query.trim();
      if (!trimmed) return;
      pushHistory(trimmed);
      refreshSearch(trimmed);
    },
    [pushHistory, refreshSearch],
  );

  // 成员事实来自服务端 is_member 与用户级成员事件，不能由部分群目录是否命中推断。
  // 自动刷新完成前保留当前结果；请求途中发生的成员事件优先于更早的响应。
  useEffect(() => {
    const membershipChanged = (id: string, member: boolean) => {
      membershipChanges.current.set(id, { member, revision: ++membershipRevision.current });
      invalidateSearchPages();
      const current = resultRef.current;
      if (current?.groups) commitResults({ ...current, groups: { ...current.groups,
        items: current.groups.items.map((group) => group.id === id ? { ...group, is_member: member } : group),
      } }, scope, searchPageMemory.get(scope)?.updatedAt ?? Date.now(), true);
      setStale(true);
    };
    const off = chatWS.onFrame((frame: ChatServerFrame) => {
      if (!active.current || activeScope.current !== scope || searchScope(q, filter) !== scope) return;
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
        if (q) {
          invalidateSearchPages();
          setStale(true);
          const cached = searchPageMemory.get(scope);
          if (cached) searchPageMemory.set(scope, { ...cached, stale: true });
        }
      } else if (frame.type === "group.joined") {
        membershipChanged(frame.conversation.id, true);
        setAcceptedGroupIds((current) => {
          const next = new Set(current);
          next.delete(frame.conversation.id);
          return next;
        });
        if (q) {
          setStale(true);
          const cached = searchPageMemory.get(scope);
          if (cached) searchPageMemory.set(scope, { ...cached, stale: true });
        }
      } else if (frame.type === "group.member.left" && frame.data.member_id === useAuthStore.getState().currentUser?.id) {
        membershipChanged(frame.data.conversation_id, false);
      }
    });
    return off;
  }, [q, filter, scope, commitResults]);

  // 五类分组是否全空（决定无结果空态）
  const hasAnyResult = useCallback((r: SearchResults | null): boolean => {
    if (!r) return false;
    return [r.users, r.groups, r.posts, r.lives, r.games].some(
      (g) => (g?.total ?? 0) > 0,
    );
  }, []);

  // URL q 驱动：进入 /search?q=… 或顶栏/历史更新 q 时自动搜索
  useEffect(() => {
    active.current = true;
    searchRequestRef.current += 1;
    appendRequests.current.clear();
    membershipChanges.current.clear();
    setPageStatus({});
    setLoading(false);
    setError(null);
    setSelectedGroup(null);
    setSelectedUser(null);
    setJoinBusy(false);
    setAcceptedGroupIds(new Set());
    setResumeEntry(false);
    const cached = searchPageMemory.get(scope);
    if (q.trim() && cached) {
      restoredScope.current = scope;
      commitResults(cached.results, scope, cached.updatedAt);
      setStale(cached.stale || Date.now() - cached.updatedAt > 60_000);
    } else {
      restoredScope.current = null;
      resultRef.current = null;
      setResultData(null);
      setResultScope(scope);
      setStale(false);
      if (q.trim()) doSearch(q);
    }
    return () => { active.current = false; searchRequestRef.current += 1; appendRequests.current.clear(); };
  }, [scope, q, doSearch, commitResults]);

  /** 历史 chips / 表单提交统一走 URL，与顶栏输入框同步 */
  const submitQuery = (query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    // replace：搜索词变更不进历史栈，返回键直接回上一个界面
    setSearchParams(filter === "all" ? { q: trimmed } : { q: trimmed, type: filter }, { replace: true });
  };

  // 搜索结果可能过时（成员关系变化/缓存过期）→ 自动重新搜索，不打扰用户；
  // 刷新失败（真实错误）停止自动刷新，显示错误+重试；刷新期间再有成员事件
  // 会保持 stale 继续刷新，直到数据稳定。
  useEffect(() => {
    if (stale && q.trim() && !loading && !error) refreshSearch(q);
  }, [stale, q, loading, error, refreshSearch]);

  return (
    <div className="search-page directory-page">
      <div className="directory-body">
        <DirectoryFilters id={filterId} label="搜索分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="search-filters" buttonClassName="search-filter" onChange={(next) => {
            saveScrollPosition(scope, pageRef.current);
            const params = new URLSearchParams(searchParams);
            if (next === "all") params.delete("type");
            else params.set("type", next);
            setSearchParams(params, { replace: true });
          }} />
        <div key={scope} className="directory-content search-content" ref={pageRef} aria-busy={loading}
          id={`${filterId}-panel`} role="tabpanel" aria-labelledby={`${filterId}-${filter}`} tabIndex={0}
          data-search-filter={filter}>
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
      {resultScope === scope && error && <div className="search-error" role="alert">
        <p>{error}</p><button type="button" className="btn btn-ghost" onClick={() => doSearch(q)}>重试搜索</button>
      </div>}

      {results && hasAnyResult(results) && (
        <div className="search-results">
          <ResultGroup
            title="用户"
            count={results.users?.total ?? 0}
            hasMore={results.users?.has_more ?? false}
            loading={loading || Boolean(pageStatus.users?.loading)}
            error={pageStatus.users?.error ?? null}
            onMore={() => void loadMore("users")}
          >
            {(results.users?.items ?? []).map((u) => (
              <div key={u.id} className="search-row search-user-row">
                <Avatar
                  label={u.nickname || u.username}
                  size={36}
                  online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, u))}
                  imageUrl={u.avatar || null}
                  onClick={() => {
                    saveScrollPosition(scope, pageRef.current);
                    goUserProfile(useAuthStore.getState().currentUser?.id, u.id);
                  }}
                  ariaLabel={`查看 ${u.nickname || u.username} 的个人主页`}
                />
                <button type="button" className="search-row-copy search-row-main" onClick={() => setSelectedUser(u)}>
                  <span className="search-row-title">{u.nickname || u.username}</span>
                  {u.signature && <span className="search-row-sub">{u.signature}</span>}
                </button>
              </div>
            ))}
          </ResultGroup>

          <ResultGroup title="群聊" count={results.groups?.total ?? 0} hasMore={results.groups?.has_more ?? false}
            loading={loading || Boolean(pageStatus.groups?.loading)} error={pageStatus.groups?.error ?? null} onMore={() => void loadMore("groups")}>
            {(results.groups?.items ?? []).map((g) => {
              const joined = groupIsJoined(g);
              const accepted = acceptedGroupIds.has(g.id);
              return (
                <button
                  key={g.id}
                  type="button"
                  className="search-row search-group-row"
                  onClick={() => {
                    if (joined) openPath(`/group/${g.id}`);
                    else if (!accepted) openGroupApply(g);
                  }}
                >
                  <Avatar label={g.title} size={36} imageUrl={g.avatar || null} />
                  <span className="search-row-title">{g.title}</span>
                  <span className="search-row-action">{joined ? "已加入" : accepted ? "已通过" : "申请入群"}</span>
                </button>
              );
            })}
          </ResultGroup>

          <ResultGroup title="帖子" count={results.posts?.total ?? 0} hasMore={results.posts?.has_more ?? false}
            loading={loading || Boolean(pageStatus.posts?.loading)} error={pageStatus.posts?.error ?? null} onMore={() => void loadMore("posts")}>
            {(results.posts?.items ?? []).map((p) => (
              <button key={p.id} type="button" className="search-row" onClick={() => openPath(`/posts/${p.id}`)}>
                <span className="search-row-title">{p.title || p.body.slice(0, 30)}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="直播间" count={results.lives?.total ?? 0} hasMore={results.lives?.has_more ?? false}
            loading={loading || Boolean(pageStatus.lives?.loading)} error={pageStatus.lives?.error ?? null} onMore={() => void loadMore("lives")}>
            {(results.lives?.items ?? []).map((l) => (
              <button key={l.id} type="button" className="search-row" onClick={() => openPath(`/live/${l.id}`)}>
                <span className="search-row-title">{l.title}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="桌游室" count={results.games?.total ?? 0} hasMore={results.games?.has_more ?? false}
            loading={loading || Boolean(pageStatus.games?.loading)} error={pageStatus.games?.error ?? null} onMore={() => void loadMore("games")}>
            {(results.games?.items ?? []).map((g) => (
              <button key={g.id} type="button" className="search-row" onClick={() => openPath(`/games/${g.id}`)}>
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

        </div>
      </div>

      {resultScope === scope && selectedUser && (
        <div className="user-profile-overlay" onClick={() => setSelectedUser(null)}>
          <div onClick={(e) => e.stopPropagation()}>
            <UserProfileCard user={selectedUser} onClose={() => setSelectedUser(null)} />
          </div>
        </div>
      )}

      {resultScope === scope && selectedGroup && (
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

function ResultGroup({ title, count, children, hasMore, loading, error, onMore }: {
  title: string;
  count: number;
  children: React.ReactNode;
  hasMore: boolean;
  loading: boolean;
  error: string | null;
  onMore: () => void;
}) {
  if (count === 0) return null;
  return (
    <section className="search-group" aria-busy={loading}>
      <div className="search-group-head">
        <span className="search-group-title">{title}</span>
      </div>
      <div className="search-group-body">{children}</div>
      {(hasMore || error) && (
        <StablePaginationFooter className="home-load-more" role={error ? "alert" : "status"} aria-busy={loading}>
          {error && <span>{error}</span>}
          <button type="button" className="btn btn-ghost" disabled={loading} onClick={onMore}
            aria-label={error ? `重试加载${title}` : `加载更多${title}`}>
            {loading ? "加载中…" : error ? "重试" : "查看更多"}
          </button>
        </StablePaginationFooter>
      )}
    </section>
  );
}
