/**
 * QuickMessagesSheet —— 红点快捷消息栏（R-QM，窄屏非导航页左下角红点按钮触发）。
 *
 * 从视口底部滑入占 70% 高度的消息面板，上方 30% 为遮罩（点击关闭）；不改变当前路由。
 * 两个选项卡：
 * - 私信：爱莉入口 + 会话列表，点会话**内联**打开聊天（PrivateChatPane，不跳 /chat/:id）；
 * - 认证消息：与 /messages 认证消息 tab 同构（退群通知/好友申请/群邀请/入群申请 + 同意/拒绝）。
 * 栏内所有操作不跳转新页面：头像一律不可点（disableAvatarNav）。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import * as chatApi from "../../api/chat";
import { getElysiaProfile } from "../../api/elysia";
import * as usersApi from "../../api/users";
import type {
  ElysiaProfile,
  FriendRequest,
  GroupInvite,
  GroupJoinRequest,
  GroupMemberLeaveNotice,
} from "../../api/types";
import { Avatar } from "../Avatar";
import { IconClose } from "../icons";
import { useAuthStore } from "../../stores/auth";
import { useBadgesStore } from "../../stores/badges";
import { useChatStore, isChatStale, sortPrivateByActivity } from "../../stores/chat";
import { useNoticeStore } from "../../stores/notices";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { chatWS } from "../../ws/chat";
import { ConversationList } from "./ConversationList";
import { ElysiaEntry } from "./ElysiaEntry";
import { PrivateChatPane } from "./PrivateChatPane";

type Tab = "chat" | "requests";

export function QuickMessagesSheet({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>("chat");
  /** 私信 tab 内联打开的会话 id；null = 列表态 */
  const [activeChatId, setActiveChatId] = useState<string | null>(null);

  const currentUser = useAuthStore((s) => s.currentUser);
  const conversations = useChatStore((s) => s.conversations);
  const realtimeNotices = useNoticeStore((s) => s.notices);
  const dismissNotice = useNoticeStore((s) => s.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");

  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [leaveNotices, setLeaveNotices] = useState<GroupMemberLeaveNotice[]>([]);
  const [friendRequests, setFriendRequests] = useState<FriendRequest[]>([]);
  const [invites, setInvites] = useState<GroupInvite[]>([]);
  const [joinRequests, setJoinRequests] = useState<GroupJoinRequest[]>([]);
  const [actionError, setActionError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [requestsError, setRequestsError] = useState<string | null>(null);

  // ESC 关闭
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  // 爱莉入口（私信 tab 顶部）
  useEffect(() => {
    getElysiaProfile()
      .then((p) => setElysiaProfile(p.enabled ? p : null))
      .catch(() => {
        /* 爱莉入口静默降级：加载失败不展示 */
      });
  }, []);

  // 会话列表（私信 tab 复用；main 已预加载，此处兜底过期/空）
  useEffect(() => {
    if (conversations.length === 0 || isChatStale()) {
      chatApi
        .listConversations()
        .then((l) => useChatStore.getState().setConversations(l))
        .catch((e) => setLoadError(e instanceof Error ? e.message : "加载会话失败"));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 认证消息数据（与 /messages 认证消息 tab 同源：好友申请/群邀请/退群通知/入群申请）
  const loadRequests = useCallback(() => {
    setRequestsError(null);
    usersApi
      .listFriendRequests()
      .then(setFriendRequests)
      .catch((e) => setRequestsError(e instanceof Error ? e.message : "加载好友申请失败"));
    chatApi
      .listMyInvites()
      .then((l) => setInvites(l.filter((i) => i.status === "pending")))
      .catch((e) => setRequestsError(e instanceof Error ? e.message : "加载群邀请失败"));
    chatApi
      .listLeaveNotices()
      .then(setLeaveNotices)
      .catch((e) => setRequestsError(e instanceof Error ? e.message : "加载退群通知失败"));
    const managed = conversations.filter(
      (c) => c.type === "group" && (c.my_role === "owner" || c.my_role === "admin"),
    );
    Promise.all(managed.map((g) => chatApi.listJoinRequests(g.id)))
      .then((lists) => setJoinRequests(lists.flat().filter((r) => r.status === "pending")))
      .catch((e) => setRequestsError(e instanceof Error ? e.message : "加载入群申请失败"));
  }, [conversations]);

  useEffect(() => {
    if (tab === "requests") loadRequests();
  }, [tab, loadRequests]);

  // 认证相关 WS 事件 → 实时刷新（与 MessagesPage 一致）
  useEffect(() => {
    const off = chatWS.onFrame((frame) => {
      if (
        frame.type === "friend.request.new" ||
        frame.type === "friend.request.resolved" ||
        frame.type === "group.invite.new" ||
        frame.type === "group.request.new" ||
        frame.type === "group.request.resolved"
      ) {
        if (tab === "requests") loadRequests();
      }
    });
    return off;
  }, [tab, loadRequests]);

  // 认证消息 tab 红点
  const badges = useBadgesStore((s) => s.badges);
  const requestBadgeCount = badges ? useBadgesStore.getState().requestBadge() : 0;

  const refreshBadges = () => void useBadgesStore.getState().fetch();

  // 打开与某用户（爱莉/会话）的私聊，栏内联（不跳路由）
  const openUserChat = useCallback((userId: string) => {
    setActionError(null);
    chatApi
      .openPrivateConversation(userId)
      .then((conv) => setActiveChatId(conv.id))
      .catch((e) => setActionError(e instanceof Error ? e.message : "打开私聊失败"));
  }, []);

  const handleFriendAction = useCallback((req: FriendRequest, action: "accept" | "reject") => {
    usersApi
      .actionFriendRequest(req.id, action)
      .then(() => {
        setFriendRequests((prev) => prev.filter((r) => r.id !== req.id));
        refreshBadges();
      })
      .catch((e) => setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试"));
  }, []);

  const handleInviteAction = useCallback((inv: GroupInvite, action: "accept" | "reject") => {
    chatApi
      .actionGroupInvite(inv.id, action)
      .then(() => {
        setInvites((prev) => prev.filter((i) => i.id !== inv.id));
        refreshBadges();
      })
      .catch((e) => setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试"));
  }, []);

  const handleJoinRequestAction = useCallback((req: GroupJoinRequest, action: "accept" | "reject") => {
    chatApi
      .actionJoinRequest(req.id, action)
      .then(() => {
        setJoinRequests((prev) => prev.filter((r) => r.id !== req.id));
        refreshBadges();
      })
      .catch((e) => setActionError(e instanceof Error ? e.message : "操作失败，请稍后重试"));
  }, []);

  const conversationActivityAt = useChatStore((s) => s.conversationActivityAt);
  const privateConvs = useMemo(
    () =>
      sortPrivateByActivity(
        conversations.filter((c) => c.type === "private"),
        conversationActivityAt,
      ),
    [conversations, conversationActivityAt],
  );
  const pendingFriendRequests = useMemo(
    () => friendRequests.filter((r) => r.to_user.id === currentUser?.id && r.status === "pending"),
    [friendRequests, currentUser?.id],
  );

  const requestsEmpty =
    pendingFriendRequests.length === 0 &&
    invites.length === 0 &&
    joinRequests.length === 0 &&
    leaveNotices.length === 0 &&
    realtimeLeaveNotices.length === 0;

  return (
    <div className="quick-messages-overlay">
      {/* 上方 30% 遮罩：点击关闭 */}
      <div className="quick-messages-scrim" onClick={onClose} aria-hidden="true" />
      <div className="quick-messages-panel" role="dialog" aria-label="快捷消息">
        <header className="quick-messages-head">
          <div className="messages-tabs quick-messages-tabs" role="tablist" aria-label="快捷消息">
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
              aria-selected={tab === "requests"}
              className={`messages-tab messages-tab-requests ${tab === "requests" ? "is-active" : ""}`}
              onClick={() => setTab("requests")}
            >
              认证消息
              {requestBadgeCount > 0 && (
                <span className="messages-tab-badge">{requestBadgeCount}</span>
              )}
            </button>
          </div>
          <button type="button" className="icon-btn-40" aria-label="关闭快捷消息" onClick={onClose}>
            <IconClose width={20} height={20} />
          </button>
        </header>

        {actionError && (
          <div className="messages-action-error" role="alert" onClick={() => setActionError(null)}>
            {actionError}（点击关闭）
          </div>
        )}
        {loadError && <div className="chat-notice" role="alert">{loadError}</div>}

        {activeChatId ? (
          <div className="quick-messages-chat">
            <PrivateChatPane
              key={activeChatId}
              conversationId={activeChatId}
              onBack={() => setActiveChatId(null)}
              backLabel="返回私信列表"
              disableAvatarNav
            />
          </div>
        ) : tab === "chat" ? (
          <div className="messages-private quick-messages-private">
            {elysiaProfile && (
              <ElysiaEntry profile={elysiaProfile} onEnter={() => openUserChat(elysiaProfile.user.id)} />
            )}
            <ConversationList
              conversations={privateConvs}
              activeId={null}
              elysiaUserId={elysiaProfile?.user.id ?? null}
              onSelect={(id) => setActiveChatId(id)}
              onError={setActionError}
              disableAvatarNav
            />
          </div>
        ) : (
          <div className="messages-friends quick-messages-requests" aria-label="认证消息">
            {requestsError && <div className="chat-notice" role="alert">{requestsError}</div>}
            {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0) && (
              <section className="messages-group">
                <h3 className="messages-group-title">退群通知</h3>
                {leaveNotices.map((notice) => (
                  <div key={`persisted-${notice.id}`} className="request-row notice-row">
                    <div className="request-body">
                      <span className="request-name">群成员已离开</span>
                      <span className="request-msg">
                        {notice.conversation_title}：{notice.member_name} 已离开
                      </span>
                    </div>
                    <button
                      type="button"
                      className="btn btn-ghost request-btn"
                      onClick={() => {
                        void chatApi.readLeaveNotice(notice.id);
                        setLeaveNotices((items) => items.filter((item) => item.id !== notice.id));
                      }}
                    >
                      知道了
                    </button>
                  </div>
                ))}
                {realtimeLeaveNotices.map((notice) => (
                  <div key={notice.id} className="request-row notice-row">
                    <div className="request-body">
                      <span className="request-name">{notice.title}</span>
                      <span className="request-msg">{notice.detail}</span>
                    </div>
                    <button
                      type="button"
                      className="btn btn-ghost request-btn"
                      onClick={() => dismissNotice(notice.id)}
                    >
                      知道了
                    </button>
                  </div>
                ))}
              </section>
            )}
            {pendingFriendRequests.length > 0 && (
              <section className="messages-group">
                <h3 className="messages-group-title">好友申请</h3>
                {pendingFriendRequests.map((r) => (
                  <RequestRow
                    key={r.id}
                    avatar={r.from_user}
                    name={r.from_user.nickname || r.from_user.username}
                    message={r.message}
                    onAccept={() => void handleFriendAction(r, "accept")}
                    onReject={() => void handleFriendAction(r, "reject")}
                  />
                ))}
              </section>
            )}
            {invites.length > 0 && (
              <section className="messages-group">
                <h3 className="messages-group-title">群邀请</h3>
                {invites.map((i) => (
                  <RequestRow
                    key={i.id}
                    avatar={i.inviter}
                    name={i.conversation_title}
                    message="邀请你加入群聊"
                    onAccept={() => void handleInviteAction(i, "accept")}
                    onReject={() => void handleInviteAction(i, "reject")}
                  />
                ))}
              </section>
            )}
            {joinRequests.length > 0 && (
              <section className="messages-group">
                <h3 className="messages-group-title">入群申请（群主/管理员）</h3>
                {joinRequests.map((r) => (
                  <RequestRow
                    key={r.id}
                    avatar={r.applicant}
                    name={r.applicant.nickname || r.applicant.username}
                    message={r.message ? r.conversation_title + "：" + r.message : r.conversation_title}
                    onAccept={() => void handleJoinRequestAction(r, "accept")}
                    onReject={() => void handleJoinRequestAction(r, "reject")}
                  />
                ))}
              </section>
            )}
            {requestsEmpty && <p className="messages-empty">暂无待处理认证消息</p>}
          </div>
        )}
      </div>
    </div>
  );
}

/** 认证消息行（头像不可点，与 MessagesPage/WideMessagesSidebar 的 RequestRow 同构） */
function RequestRow({
  avatar,
  name,
  message,
  onAccept,
  onReject,
}: {
  avatar: Pick<import("../../api/types").UserPublic, "id" | "status" | "nickname" | "username" | "avatar" | "online">;
  name: string;
  message: string;
  onAccept: () => void;
  onReject: () => void;
}) {
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  return (
    <div className="request-row">
      <Avatar label={avatar.nickname || avatar.username} size={36} online={presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, avatar))} imageUrl={avatar.avatar || null} />
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
