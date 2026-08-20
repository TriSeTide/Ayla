/**
 * MessagesPage —— 消息中心（路由 /messages，F8，R-M1~M5）。
 *
 * 窄屏（≤768px）：NarrowTopBar + 双选项卡（私信/好友列表），点会话跳 /chat/:id。
 * 宽屏（>768px）：两列——左 260px 会话列表侧栏（WideMessagesSidebar，宽度与主页
 *  ChannelSidebar 一致）+ 右侧聊天内容区（选中会话内联 PrivateChatPane，不跳转 URL）。
 * 申请条目：好友申请 + 群邀请 + 待审批入群申请，同意/拒绝即时反馈。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as chatApi from "../api/chat";
import { getElysiaProfile } from "../api/elysia";
import * as usersApi from "../api/users";
import type { ElysiaProfile, FriendRequest, GroupInvite, GroupJoinRequest } from "../api/types";
import { Avatar } from "../components/Avatar";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";
import { ConversationList } from "../components/chat/ConversationList";
import { ElysiaEntry } from "../components/chat/ElysiaEntry";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useBadgesStore } from "../stores/badges";
import { useChatStore, isChatStale } from "../stores/chat";
import { useAuthStore } from "../stores/auth";
import { useNoticeStore } from "../stores/notices";
import { goUserProfile } from "../utils/navigation";

type Tab = "chat" | "friends" | "requests";

export function MessagesPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const currentUser = useAuthStore((state) => state.currentUser);
  const realtimeNotices = useNoticeStore((state) => state.notices);
  const dismissNotice = useNoticeStore((state) => state.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");
  const [leaveNotices, setLeaveNotices] = useState<import("../api/types").GroupMemberLeaveNotice[]>([]);
  const [tab, setTab] = useState<Tab>("chat");
  // 宽屏右侧选中的私聊会话 id（内联聊天）
  const [activeChatId, setActiveChatId] = useState<string | null>(null);
  const conversations = useChatStore((s) => s.conversations);
  const [friendList, setFriendList] = useState<Awaited<ReturnType<typeof usersApi.listFriends>>>([]);
  const [friendRequests, setFriendRequests] = useState<FriendRequest[]>([]);
  const [invites, setInvites] = useState<GroupInvite[]>([]);
  const [joinRequests, setJoinRequests] = useState<GroupJoinRequest[]>([]);
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  /** 审批（同意/拒绝）失败提示（点击关闭） */
  const [actionError, setActionError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [friendsLoadError, setFriendsLoadError] = useState<string | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [removingFriendId, setRemovingFriendId] = useState<string | null>(null);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    getElysiaProfile()
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch((e) => setProfileError(e instanceof Error ? e.message : "加载爱莉资料失败"));
  }, []);

  // 加载会话列表（私信 tab 复用）
  useEffect(() => {
    if (conversations.length === 0 || isChatStale()) {
      chatApi.listConversations()
        .then((l) => useChatStore.getState().setConversations(l))
        .catch((e) => setLoadError(e instanceof Error ? e.message : "加载会话失败"));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 好友 tab 数据（窄屏用；宽屏由 WideMessagesSidebar 自理）
  const loadFriendsTab = useCallback(() => {
    setFriendsLoadError(null);
    usersApi.listFriends().then(setFriendList).catch((e) => setFriendsLoadError(e instanceof Error ? e.message : "加载好友失败"));
    usersApi.listFriendRequests().then(setFriendRequests).catch((e) => setFriendsLoadError(e instanceof Error ? e.message : "加载好友申请失败"));
    chatApi.listMyInvites().then((l) => setInvites(l.filter((i) => i.status === "pending"))).catch((e) => setFriendsLoadError(e instanceof Error ? e.message : "加载群邀请失败"));
    chatApi.listLeaveNotices().then(setLeaveNotices).catch((e) => setFriendsLoadError(e instanceof Error ? e.message : "加载退群通知失败"));
    // 我管理的群 → 待审批入群申请
    const managed = conversations.filter((c) => c.type === "group" && (c.my_role === "owner" || c.my_role === "admin"));
    Promise.all(managed.map((g) => chatApi.listJoinRequests(g.id)))
      .then((lists) => setJoinRequests(lists.flat().filter((r) => r.status === "pending")))
      .catch((e) => setFriendsLoadError(e instanceof Error ? e.message : "加载入群申请失败"));
  }, [conversations]);

  useEffect(() => {
    if ((tab === "friends" || tab === "requests") && isNarrow) loadFriendsTab();
  }, [tab, isNarrow, loadFriendsTab]);

  const refreshBadges = () => void useBadgesStore.getState().fetch();

  const handleRemoveFriend = useCallback(async (userId: string) => {
    if (removingFriendId) return;
    setActionError(null);
    setRemovingFriendId(userId);
    try {
      await usersApi.deleteFriend(userId);
      setFriendList((prev) => prev.filter((item) => item.user.id !== userId));
      refreshBadges();
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "解除好友失败");
    } finally {
      setRemovingFriendId(null);
    }
  }, [removingFriendId]);

  // 好友申请处理
  const handleFriendAction = useCallback((req: FriendRequest, action: "accept" | "reject") => {
    usersApi.actionFriendRequest(req.id, action).then(() => {
      setFriendRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  // 群邀请处理
  const handleInviteAction = useCallback((inv: GroupInvite, action: "accept" | "reject") => {
    chatApi.actionGroupInvite(inv.id, action).then(() => {
      setInvites((prev) => prev.filter((i) => i.id !== inv.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  // 入群申请审批
  const handleJoinRequestAction = useCallback((req: GroupJoinRequest, action: "accept" | "reject") => {
    chatApi.actionJoinRequest(req.id, action).then(() => {
      setJoinRequests((prev) => prev.filter((r) => r.id !== req.id));
      refreshBadges();
    }).catch((e) => {
      setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试");
    });
  }, []);

  const privateConvs = useMemo(() => conversations.filter((c) => c.type === "private"), [conversations]);

  // 宽屏两列：左会话列表侧栏 + 右聊天内容区
  if (!isNarrow) {
    return (
      <div className="messages-page messages-page-wide">
        <WideMessagesSidebar
          activeId={activeChatId}
          onSelect={(id) => setActiveChatId(id)}
        />
        <div className="wide-messages-pane">
          {activeChatId ? (
            <PrivateChatPane key={activeChatId} conversationId={activeChatId} />
          ) : (
            <div className="wide-messages-empty">
              <h3 className="placeholder-title">选择一个会话开始聊天</h3>
              <p className="placeholder-desc">左侧会话列表，点击进入私聊</p>
            </div>
          )}
        </div>
      </div>
    );
  }

  // 窄屏：双选项卡 + 列表，点会话跳 /chat/:id
  return (
    <div className="messages-page">
      <NarrowTopBar />
      {profileError && <div className="chat-notice" role="alert">爱莉入口暂不可用：{profileError}</div>}
      {loadError && <div className="chat-notice" role="alert">{loadError}</div>}
      {actionError && (
        <div className="messages-action-error" role="alert">
          {actionError}
        </div>
      )}
      {friendsLoadError && <div className="chat-notice" role="alert">{friendsLoadError}</div>}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px' }}>
        <div className="messages-tabs" role="tablist" aria-label="消息中心" style={{ flex: 1 }}>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "chat"}
            className={`messages-tab ${tab === "chat" ? "is-active" : ""}`}
            onClick={() => setTab("chat")}
          >
            私信
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "friends"}
            className={`messages-tab ${tab === "friends" ? "is-active" : ""}`}
            onClick={() => setTab("friends")}
          >
            好友列表
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "requests"}
            className={`messages-tab messages-tab-requests ${tab === "requests" ? "is-active" : ""}`}
            onClick={() => setTab("requests")}
          >
            认证消息
            {(friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length + invites.length + joinRequests.length) > 0 && (
              <span className="messages-tab-badge">{friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length + invites.length + joinRequests.length}</span>
            )}
          </button>
        </div>
      </div>

      {tab === "chat" ? (
        <div className="messages-private">
          {elysiaProfile && (
            <ElysiaEntry
              profile={elysiaProfile}
              onEnter={() => {
                chatApi
                  .openPrivateConversation(elysiaProfile.user.id)
                  .then((conv) => navigate(`/chat/${conv.id}`))
                  .catch((e) => setActionError(e instanceof Error ? e.message : "打开爱莉私聊失败"));
              }}
            />
          )}
          <ConversationList
            conversations={privateConvs}
            activeId={null}
            elysiaUserId={elysiaProfile?.user.id ?? null}
            onSelect={(id) => navigate(`/chat/${id}`)}
          />
        </div>
      ) : tab === "friends" ? (
        <div className="messages-friends">
          <section className="messages-group">
            <h3 className="messages-group-title">我的好友（{friendList.length}）</h3>
            {friendList.map((f) => (
              <div key={f.user.id} className="friend-row">
                <button
                  type="button"
                  className="friend-row-main"
                  onClick={() => {
                    chatApi.openPrivateConversation(f.user.id)
                      .then((conv) => navigate(`/chat/${conv.id}`))
                      .catch((e) => setActionError(e instanceof Error ? e.message : "打开私聊失败"));
                  }}
                >
                  <Avatar
                    label={f.user.nickname || f.user.username}
                    size={40}
                    online={f.user.online}
                    imageUrl={f.user.avatar || null}
                    onClick={(e) => {
                      e.stopPropagation();
                      goUserProfile(useAuthStore.getState().currentUser?.id, f.user.id);
                    }}
                    ariaLabel={`查看 ${f.user.nickname || f.user.username} 的个人主页`}
                  />
                  <span className="friend-row-name">{f.user.nickname || f.user.username}</span>
                </button>
                <button
                  type="button"
                  className="btn btn-ghost friend-remove-btn"
                  disabled={removingFriendId === f.user.id}
                  onClick={() => void handleRemoveFriend(f.user.id)}
                >
                  {removingFriendId === f.user.id ? "解除中…" : "解除好友"}
                </button>
              </div>
            ))}
            {friendList.length === 0 && (
              <p className="messages-empty">还没有好友，去搜索添加吧</p>
            )}
          </section>
        </div>
      ) : (
        <div className="messages-friends messages-requests" aria-label="认证消息">
          <section className="messages-group">
            <h3 className="messages-group-title">认证消息</h3>
            <p className="messages-section-hint">好友申请、群邀请和入群申请都会集中显示在这里。</p>
          </section>
          {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0) && (
            <section className="messages-group">
              <h3 className="messages-group-title">退群通知</h3>
              {leaveNotices.map((notice) => (
                <div key={`persisted-${notice.id}`} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">群成员已离开</span><span className="request-msg">{notice.conversation_title}：{notice.member_name} 已离开</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => { void chatApi.readLeaveNotice(notice.id); setLeaveNotices((items) => items.filter((item) => item.id !== notice.id)); }}>知道了</button>
                </div>
              ))}
              {realtimeLeaveNotices.map((notice) => (
                <div key={notice.id} className="request-row notice-row">
                  <div className="request-body"><span className="request-name">{notice.title}</span><span className="request-msg">{notice.detail}</span></div>
                  <button type="button" className="btn btn-ghost request-btn" onClick={() => dismissNotice(notice.id)}>知道了</button>
                </div>
              ))}
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">好友申请</h3>
              {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").map((r) => (
                <RequestRow key={r.id} avatar={r.from_user} name={r.from_user.nickname || r.from_user.username} message={r.message} onAccept={() => handleFriendAction(r, "accept")} onReject={() => handleFriendAction(r, "reject")} />
              ))}
            </section>
          )}
          {invites.length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">群邀请</h3>
              {invites.map((i) => <RequestRow key={i.id} avatar={i.inviter} name={i.conversation_title} message="邀请你加入群聊" onAccept={() => handleInviteAction(i, "accept")} onReject={() => handleInviteAction(i, "reject")} />)}
            </section>
          )}
          {joinRequests.length > 0 && (
            <section className="messages-group">
              <h3 className="messages-group-title">入群申请（群主/管理员）</h3>
              {joinRequests.map((r) => <RequestRow key={r.id} avatar={r.applicant} name={r.applicant.nickname || r.applicant.username} message={r.message ? r.conversation_title + "：" + r.message : r.conversation_title} onAccept={() => handleJoinRequestAction(r, "accept")} onReject={() => handleJoinRequestAction(r, "reject")} />)}
            </section>
          )}
          {friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending").length === 0 && invites.length === 0 && joinRequests.length === 0 && <p className="messages-empty">暂无待处理认证消息</p>}
        </div>
      )}
    </div>
  );
}

function RequestRow({
  avatar,
  name,
  message,
  onAccept,
  onReject,
}: {
  avatar: { nickname: string; username: string; avatar: string; online: boolean };
  name: string;
  message: string;
  onAccept: () => void;
  onReject: () => void;
}) {
  return (
    <div className="request-row">
      <Avatar label={avatar.nickname || avatar.username} size={36} online={avatar.online} imageUrl={avatar.avatar || null} />
      <div className="request-body">
        <span className="request-name">{name}</span>
        {message && <span className="request-msg">{message}</span>}
      </div>
      <div className="request-actions">
        <button type="button" className="btn btn-primary request-btn" onClick={onAccept}>
          同意
        </button>
        <button type="button" className="btn btn-ghost request-btn" onClick={onReject}>
          拒绝
        </button>
      </div>
    </div>
  );
}
