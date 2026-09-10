/**
 * QuickMessagesSheet —— 红点快捷消息栏（R-QM，窄屏非导航页左下角红点按钮触发）。
 *
 * 从视口底部滑入占 70% 高度的消息面板，上方 30% 为遮罩（点击关闭）；不改变当前路由。
 * 两个选项卡：
 * - 私信：爱莉入口 + 会话列表，点会话**内联**打开聊天（PrivateChatPane，不跳 /chat/:id）；
 * - 认证消息：与 /messages 认证消息 tab 同构（退群通知/好友申请/群邀请/入群申请 + 同意/拒绝）。
 * 栏内所有操作不跳转新页面：头像一律不可点（disableAvatarNav）。
 */
import { useTabPanelMotion } from "../../hooks/useTabPanelMotion";
import { AuroraquaNavHighlight } from "../motion/AuroraquaNavHighlight";
import { useCallback, useEffect, useId, useMemo, useState } from "react";
import * as chatApi from "../../api/chat";
import { useSocialPage } from "../../hooks/useSocialPage";
import { DirectoryLoadMore } from "../../components/DirectoryLoadMore";
import { getElysiaProfile } from "../../api/elysia";
import * as usersApi from "../../api/users";
import type {
  ElysiaProfile,
  FriendRequest,
  GroupInvite,
  GroupJoinRequest,
} from "../../api/types";
import { Avatar } from "../Avatar";
import { IconClose } from "../icons";
import { useAuthStore } from "../../stores/auth";
import { useBadgesStore } from "../../stores/badges";
import { useChatStore, sortPrivateByActivity } from "../../stores/chat";
import { useNoticeStore } from "../../stores/notices";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { chatWS } from "../../ws/chat";
import { ConversationList } from "./ConversationList";
import { ElysiaEntry } from "./ElysiaEntry";
import { PrivateChatPane } from "./PrivateChatPane";

type Tab = "chat" | "requests";

export function QuickMessagesSheet({ onClose }: { onClose: () => void }) {
  const selectionId = useId();
  const [tab, setTab] = useState<Tab>("chat");
  const privatePage = useSocialPage("conversations", { type: "private" });
  const conversations = privatePage.items;
  const friendRequestPage = useSocialPage("friendRequests", {}, tab === "requests");
  const { items: friendRequests, setItems: setFriendRequests } = friendRequestPage;
  const invitePage = useSocialPage("invites", {}, tab === "requests");
  const { items: invites, setItems: setInvites } = invitePage;
  const joinPage = useSocialPage("joinRequests", {}, tab === "requests");
  const { items: joinRequests, setItems: setJoinRequests } = joinPage;
  const leavePage = useSocialPage("leaveNotices", {}, tab === "requests");
  const { items: leaveNotices, setItems: setLeaveNotices } = leavePage;

  /** 私信 tab 内联打开的会话 id；null = 列表态 */
  const [activeChatId, setActiveChatId] = useState<string | null>(null);
  const tabPanelRef = useTabPanelMotion<HTMLDivElement>(activeChatId ?? tab, ":scope > .quick-messages-chat, :scope > .messages-private, :scope > .messages-friends");

  const currentUser = useAuthStore((s) => s.currentUser);
  const realtimeNotices = useNoticeStore((s) => s.notices);
  const dismissNotice = useNoticeStore((s) => s.dismiss);
  const realtimeLeaveNotices = realtimeNotices.filter((notice) => notice.kind === "group.member.left");

  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);

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

  // 认证消息数据（与 /messages 认证消息 tab 同源：好友申请/群邀请/退群通知/入群申请）
  const refreshSocial0 = friendRequestPage.refresh;
  const refreshSocial1 = invitePage.refresh;
  const refreshSocial2 = joinPage.refresh;
  const refreshSocial3 = leavePage.refresh;
  const loadRequests = useCallback(() => {
    void refreshSocial0(); void refreshSocial1(); void refreshSocial2(); void refreshSocial3();
  }, [refreshSocial0, refreshSocial1, refreshSocial2, refreshSocial3]);

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
    chatApi
      .openPrivateConversation(userId)
      .then((conv) => setActiveChatId(conv.id))
      .catch(() => {});
  }, []);

  const handleFriendAction = useCallback((req: FriendRequest, action: "accept" | "reject") => {
    usersApi
      .actionFriendRequest(req.id, action)
      .then(() => {
        setFriendRequests((prev) => prev.filter((r) => r.id !== req.id));
        refreshBadges();
      })
      .catch(() => {});
  }, []);

  const handleInviteAction = useCallback((inv: GroupInvite, action: "accept" | "reject") => {
    chatApi
      .actionGroupInvite(inv.id, action)
      .then(() => {
        setInvites((prev) => prev.filter((i) => i.id !== inv.id));
        refreshBadges();
      })
      .catch(() => {});
  }, []);

  const handleJoinRequestAction = useCallback((req: GroupJoinRequest, action: "accept" | "reject") => {
    chatApi
      .actionJoinRequest(req.id, action)
      .then(() => {
        setJoinRequests((prev) => prev.filter((r) => r.id !== req.id));
        refreshBadges();
      })
      .catch(() => {});
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
      <div className="quick-messages-panel" role="dialog" aria-label="快捷消息" ref={tabPanelRef}>
        <header className="quick-messages-head">
          <div className="messages-tabs quick-messages-tabs" role="tablist" aria-label="快捷消息">
            <button
              type="button"
              role="tab"
              aria-selected={tab === "chat"}
              className={`messages-tab has-auroraqua-highlight ${tab === "chat" ? "is-active" : ""}`}
              onClick={() => setTab("chat")}
            >
              {tab === "chat" && <AuroraquaNavHighlight id={selectionId} />}
              <span className="auroraqua-nav-label">私信</span>
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={tab === "requests"}
              className={`messages-tab has-auroraqua-highlight messages-tab-requests ${tab === "requests" ? "is-active" : ""}`}
              onClick={() => setTab("requests")}
            >
              {tab === "requests" && <AuroraquaNavHighlight id={selectionId} />}
              <span className="auroraqua-nav-label">认证消息</span>
              {requestBadgeCount > 0 && (
                <span className="messages-tab-badge">{requestBadgeCount}</span>
              )}
            </button>
          </div>
          <button type="button" className="icon-btn-40" aria-label="关闭快捷消息" onClick={onClose}>
            <IconClose width={20} height={20} />
          </button>
        </header>

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
              disableAvatarNav
            />
          <DirectoryLoadMore {...privatePage} retainCompletedSpace={false} />
          </div>
        ) : (
          <div className="messages-friends quick-messages-requests" aria-label="认证消息">
            {(leaveNotices.length > 0 || realtimeLeaveNotices.length > 0 || leavePage.loading || !!leavePage.error || leavePage.hasMore) && (
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
                        void chatApi.readLeaveNotice(notice.id).then(() => setLeaveNotices((items) => items.filter((item) => item.id !== notice.id))).catch(() => {});
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
              <DirectoryLoadMore {...leavePage} retainCompletedSpace={false} />
            </section>
            )}
            {(pendingFriendRequests.length > 0 || friendRequestPage.loading || !!friendRequestPage.error || friendRequestPage.hasMore) && (
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
              <DirectoryLoadMore {...friendRequestPage} retainCompletedSpace={false} />
            </section>
            )}
            {(invites.length > 0 || invitePage.loading || !!invitePage.error || invitePage.hasMore) && (
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
              <DirectoryLoadMore {...invitePage} retainCompletedSpace={false} />
            </section>
            )}
            {(joinRequests.length > 0 || joinPage.loading || !!joinPage.error || joinPage.hasMore) && (
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
              <DirectoryLoadMore {...joinPage} retainCompletedSpace={false} />
            </section>
            )}
            {requestsEmpty && ![leavePage, invitePage, joinPage, friendRequestPage].some((page) => page.loading || page.error || page.hasMore) && <p className="messages-empty">暂无待处理认证消息</p>}
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
