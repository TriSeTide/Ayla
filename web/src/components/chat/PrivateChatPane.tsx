/**
 * PrivateChatPane —— 私聊聊天内容面板（宽屏消息两列 / 私聊窗口共用）。
 *
 * 含私聊头部（对端头像/昵称/在线状态 + 可选返回）+ 消息列表 + typing 指示 +
 * 输入框。复用 useChat 数据流（openConversation/loadHistory/recallMessage 等）。
 * conversationId 变化时切换会话（open bucket / 订阅 / 标已读）。
 */
import { useEffect, useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { motion, useIsPresent } from "framer-motion";
import type { ChatMessage } from "../../api/types";
import { getElysiaProfile } from "../../api/elysia";
import { getUserDetail } from "../../api/users";
import * as chatApi from "../../api/chat";
import { Avatar } from "../Avatar";
import { MessageInput } from "./MessageInput";
import { MessageList } from "./MessageList";
import { IconBack } from "../icons";
import { loadHistory, loadMoreHistory, loadHistoryUntilSeq, markConversationReadThrough, markMessageReadExact, recallMessage, retryOptimistic, removeOptimistic, cancelOptimistic } from "../../hooks/useChat";
import { useChatStore } from "../../stores/chat";
import { useMessageStore } from "../../stores/message";
import { useAuthStore } from "../../stores/auth";
import { chatWS } from "../../ws/chat";
import { goUserProfile } from "../../utils/navigation";
import { useDisplayStatus, usePresenceOnline } from "../../utils/displayStatus";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { auroraquaPanelOrchestration, panelVariants } from "../motion/auroraquaMotion";

export function PrivateChatPane({
  conversationId,
  onBack,
  backLabel = "返回消息中心",
  disableAvatarNav = false,
  panelMotion = false,
  externalJump = null,
}: {
  conversationId: string;
  /** 可选返回按钮（窄屏私聊窗口 → /messages；宽屏两列不渲染返回） */
  onBack?: () => void;
  backLabel?: string;
  /** 快捷消息栏内：头像不可点（不跳个人主页，R-QM） */
  disableAvatarNav?: boolean;
  /** Conversation panels own their entry; surrounding swipe wrappers only own the gesture. */
  panelMotion?: boolean;
  /** 收藏消息跳转定位（由路由页读取 ?msg=&seq= 后传入；私聊无子群概念） */
  externalJump?: { messageId: string; seq: number; subgroupId?: string | null } | null;
}) {
  const present = useIsPresent();
  const active = !panelMotion || present;
  const reduced = usePrefersReducedMotion();
  const rootRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => { rootRef.current?.toggleAttribute("inert", !active); }, [active]);
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[conversationId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});

  // 精确查询当前对端好友关系；爱莉身份由独立配置接口返回。
  // friendsLoaded=false（加载中/失败）→ 视为未知，不禁用输入（后端 403 权威拦截）。
  const [peerIsFriend, setPeerIsFriend] = useState(false);
  const [friendsLoaded, setFriendsLoaded] = useState(false);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);

  const conv = useMemo(
    () => conversations.find((c) => c.id === conversationId) ?? null,
    [conversations, conversationId],
  );

  const peerId = conv?.peer?.id;
  useEffect(() => {
    let cancelled = false;
    setFriendsLoaded(false);
    setPeerIsFriend(false);
    if (peerId) void getUserDetail(peerId).then((user) => {
      if (cancelled) return;
      setPeerIsFriend(user.relation === "friend" || user.relation === "self");
      setFriendsLoaded(true);
    }).catch(() => { /* Unknown relationship remains server-authorized. */ });
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.user?.id ?? null);
      })
      .catch(() => {
        // profile 未初始化/加载失败 → elysiaUserId 保持 null（走好友判断即可）
      });
    return () => {
      cancelled = true;
    };
  }, [peerId]);

  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    void chatApi.getConversationMetadata(conversationId).then((conversation) => {
      if (!cancelled) useChatStore.getState().upsertConversation(conversation);
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [conversationId, active]);

  // 打开私聊会话：拉历史 + 订阅 + 标已读
  useEffect(() => {
    if (!active) return;
    useChatStore.getState().openConversation(conversationId);
    useMessageStore.getState().openBucket(conversationId);
    chatWS.subscribe([conversationId]);
    loadHistory(conversationId, undefined, true)
      .catch(() => {});
    return () => {
      // 离开私聊（切换会话/返回消息中心）时清 activeId，避免残留导致
      // 其他会话的 message.new 被误判为"正在聊天"而 markRead（串会话）。
      const store = useChatStore.getState();
      if (store.activeConversationId === conversationId) store.closeConversation();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId, active]);

  // typing 帧：只处理当前会话、忽略自己（自己输入不显示「对方正在输入」）
  useEffect(() => {
    setPeerTyping({}); // 切换会话清空上一会话的输入状态
    if (!active) return;
    const off = chatWS.onFrame((frame) => {
      if (frame.type !== "typing") return;
      if (frame.data.conversation_id !== conversationId) return;
      const me = useAuthStore.getState().currentUser;
      if (me && String(frame.data.user_id) === String(me.id)) return;
      setPeerTyping((prev) => ({ ...prev, [frame.data.user_id]: frame.data.is_typing }));
    });
    return off;
  }, [conversationId, active]);

  const typingActive = Object.values(peerTyping).some(Boolean);

  const handleRecall = async (msg: ChatMessage) => {
    if (msg.status === "recalled") return;
    try {
      await recallMessage(conversationId, msg.id);
    } catch {
      // 撤回失败静默
    }
  };

  // 双击头像 → 戳一戳（私聊里双击任意头像都戳向对端；WS 回帧渲染与置顶排序）
  const handlePoke = useCallback(async (targetUserId: string) => {
    try {
      await chatApi.sendPoke(conversationId, targetUserId);
    } catch {
      // 戳一戳失败静默
    }
  }, [conversationId]);

  const peer = conv?.peer ?? null;
  const peerOnline = usePresenceOnline(peer);
  const peerDisplayStatus = useDisplayStatus(peer);
  const title = peer?.nickname || peer?.username || "私聊";
  // 非好友禁发：私聊 + 对端已知 + 好友列表已加载 + 对端不是爱莉 + 对端不在好友列表
  const blocked =
    conv?.type === "private" &&
    peer != null &&
    friendsLoaded &&
    !(elysiaUserId != null && peer.id === elysiaUserId) &&
    !peerIsFriend;

  return (
    <motion.div
      ref={rootRef}
      className={`private-chat${panelMotion ? " chat-motion-panels" : ""}`}
      data-chat-identity={conversationId}
      aria-hidden={!active || undefined}
      inherit={false}
      initial={panelMotion && !reduced ? "enter" : false}
      animate={panelMotion ? "center" : undefined}
      exit={panelMotion ? "exit" : undefined}
      variants={panelMotion ? auroraquaPanelOrchestration : undefined}
    >
      <motion.header
        className="private-chat-head"
        data-motion-panel="chat-header"
        inherit={panelMotion}
        variants={panelMotion ? panelVariants(reduced, "top") : undefined}
      >
        {onBack && (
          <button type="button" className="icon-btn-40" onClick={onBack} aria-label={backLabel}>
            <IconBack width={20} height={20} />
          </button>
        )}
        <Avatar
          label={title}
          size={36}
          online={peerOnline}
          imageUrl={peer?.avatar || null}
          onClick={
            !disableAvatarNav && peer && !(elysiaUserId != null && peer.id === elysiaUserId)
              ? () => goUserProfile(null, peer.id)
              : undefined
          }
          ariaLabel={!disableAvatarNav && peer ? `查看 ${title} 的个人主页` : undefined}
        />
        <div className="private-chat-title">
          <span className="private-chat-name">{title}</span>
          {/* 「对方正在输入」字样显示在顶栏好友名字下方（替换在线状态行，不加高栏） */}
          <span
            className={`private-chat-status${typingActive ? " is-typing" : ""}`}
            role={typingActive ? "status" : undefined}
          >
            {typingActive ? "对方正在输入…" : peerDisplayStatus}
          </span>
        </div>
      </motion.header>

      <motion.div
        className="chat-messages-motion"
        data-motion-panel="chat-messages"
        inherit={panelMotion}
        variants={panelMotion ? panelVariants(reduced, "right", "left") : undefined}
      >
      <MessageList
        messages={messages}
        conversation={conv}
        elysiaUserId={elysiaUserId}
        hasMore={bucket?.hasMore ?? false}
        loading={bucket?.loading ?? false}
        onLoadMore={() => loadMoreHistory(conversationId)}
        onQuote={setQuote}
        onMarkRead={(m, exact) => active && exact ? markMessageReadExact(conversationId, m.id) : undefined}
        onMarkConversationRead={(throughSeq, excluded) => active ? markConversationReadThrough(conversationId, throughSeq, excluded) : undefined}
        onLoadUntilSeq={(targetSeq) => loadHistoryUntilSeq(conversationId, targetSeq).catch(() => false)}
        onRecall={(m) => void handleRecall(m)}
        onRetry={(m) => retryOptimistic(conversationId, m)}
        onRemove={(m) => removeOptimistic(conversationId, m)}
        onCancel={(m) => cancelOptimistic(conversationId, m)}
        onPoke={handlePoke}
        externalJump={externalJump}
      />
      </motion.div>
      <motion.div
        className="chat-composer-motion"
        data-motion-panel="chat-composer"
        inherit={panelMotion}
        variants={panelMotion ? panelVariants(reduced, "bottom") : undefined}
      >
      {blocked ? (
        <div className="private-chat-blocked" role="alert">
          对方已不是你的好友，无法发送消息
        </div>
      ) : (
        <>
          <MessageInput convId={conversationId} quote={quote} onQuoteClear={() => setQuote(null)} disabled={!active} />
        </>
      )}
      </motion.div>
    </motion.div>
  );
}
