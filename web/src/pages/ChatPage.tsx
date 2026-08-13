/**
 * ChatPage —— 聊天主页（整屏：左玻璃侧栏 + 右聊天窗口）。
 *
 * 状态与数据逻辑与 M5-1/M5-2 契约保持一致：
 * - 会话列表 GET /chat/conversations/；打开会话拉历史 + 订阅 WS + 标已读；
 * - 幂等发送 / 撤回 / 引用 / typing / 历史分页全部复用 hooks/useChat；
 * - 后端不可达时注入演示数据（明确标记演示横幅）。
 * 视觉：design.md「千禧冰樱」——玻璃侧栏 + 极光主区 + 气泡三态 + 在线光环。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as chatApi from "../api/chat";
import { getElysiaProfile } from "../api/elysia";
import { checkLive } from "../api/health";
import type { ChatMessage, ConversationSummary, ElysiaProfile } from "../api/types";
import { Avatar } from "../components/Avatar";
import { ConversationList } from "../components/chat/ConversationList";
import { ConversationSearch } from "../components/chat/ConversationSearch";
import { ElysiaEntry } from "../components/chat/ElysiaEntry";
import { MessageInput } from "../components/chat/MessageInput";
import { MessageList } from "../components/chat/MessageList";
import { TypingIndicator } from "../components/chat/TypingIndicator";
import { IconMenu } from "../components/icons";
import { loadHistory, loadMoreHistory, markReadLatest, recallMessage } from "../hooks/useChat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { usePresenceStore } from "../stores/presence";
import { chatWS } from "../ws/chat";

/* ---------- 演示数据（仅后端不可达时注入，界面明确标记） ---------- */

const DEMO_CONVERSATIONS: ConversationSummary[] = [
  {
    id: "demo-1",
    type: "private",
    title: "演示用户",
    announcement: "",
    owner_id: "demo-owner",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: 1,
    created_at: new Date().toISOString(),
    peer: {
      id: "demo-peer",
      username: "demo_peer",
      nickname: "演示用户",
      avatar: "",
      signature: "",
      status: "online",
      online: true,
      date_joined: new Date().toISOString(),
    },
  },
  {
    id: "demo-2",
    type: "group",
    title: "演示群聊",
    announcement: "用于预览聊天界面",
    owner_id: "demo-owner",
    members: [],
    my_role: "owner",
    member_count: 3,
    unread_count: 0,
    created_at: new Date().toISOString(),
    peer: null,
  },
];

function demoMessages(convId: string): ChatMessage[] {
  const now = Date.now();
  const mk = (
    i: number,
    sender: string,
    content: string,
    minutesAgo: number,
  ): ChatMessage => ({
    id: `${convId}-demo-${i}`,
    conversation_id: convId,
    sender_id: sender,
    type: "text",
    content,
    media_id: null,
    media: null,
    reply_to: null,
    status: "read",
    seq: i,
    created_at: new Date(now - minutesAgo * 60_000).toISOString(),
  });
  if (convId === "demo-1") {
    return [
      mk(1, "demo-peer", "你好，这是演示私聊会话（后端未连接时展示）", 12),
      mk(2, "demo-peer", "媒体消息需要真实后端提供 descriptor 才能渲染", 11),
      mk(3, "me", "收到，界面重做完成", 2),
    ];
  }
  return [mk(1, "demo-user-a", "大家好", 30), mk(2, "demo-user-b", "欢迎来到演示群", 29)];
}

/* ---------- 页面 ---------- */

export function ChatPage() {
  const { conversationId } = useParams();
  const navigate = useNavigate();
  const currentUser = useAuthStore((s) => s.currentUser);
  const conversations = useChatStore((s) => s.conversations);
  const listLoading = useChatStore((s) => s.loading);
  const activeId = useChatStore((s) => s.activeConversationId);
  const presenceConnection = usePresenceStore((s) => s.connection);

  const buckets = useMessageStore((s) => s.buckets);
  const bucket = conversationId ? buckets[conversationId] : undefined;
  const messages = bucket?.messages ?? [];

  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [demoMode, setDemoMode] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [backendAlive, setBackendAlive] = useState<boolean | null>(null);

  // 后端存活探针（侧栏底部状态）
  useEffect(() => {
    let cancelled = false;
    checkLive().then((r) => {
      if (!cancelled) setBackendAlive(r?.status === "alive");
    });
    return () => {
      cancelled = true;
    };
  }, []);

  // 加载会话列表
  useEffect(() => {
    let cancelled = false;
    const { setLoading, setConversations, setError } = useChatStore.getState();
    setLoading(true);
    setError(null);
    chatApi
      .listConversations()
      .then((list) => {
        if (cancelled) return;
        if (list.length === 0) {
          setDemoMode(true);
          setConversations(DEMO_CONVERSATIONS);
        } else {
          setDemoMode(false);
          setConversations(list);
        }
      })
      .catch((e) => {
        if (cancelled) return;
        setDemoMode(true);
        setConversations(DEMO_CONVERSATIONS);
        setNotice(`后端未连接（${e instanceof Error ? e.message : "网络错误"}），当前展示演示数据`);
        setError(null);
      })
      .finally(() => {
        if (!cancelled) useChatStore.getState().setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // 爱莉 profile（存在则展示入口卡）
  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaProfile(p.enabled ? p : null);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  // 打开会话：拉历史 + 订阅 + 标已读
  useEffect(() => {
    if (!conversationId) return;
    useChatStore.getState().openConversation(conversationId);
    if (conversationId.startsWith("demo-")) {
      useMessageStore.getState().prependHistory(conversationId, demoMessages(conversationId), false);
      useChatStore.getState().clearUnread(conversationId);
    } else {
      useMessageStore.getState().openBucket(conversationId);
      loadHistory(conversationId, undefined, true).catch(() => {});
    }
    chatWS.subscribe([conversationId]);
    markReadLatest(conversationId).catch(() => {});
  }, [conversationId]);

  // 对端 typing 帧
  useEffect(() => {
    const off = chatWS.onFrame((frame) => {
      if (frame.type === "typing") {
        setPeerTyping((prev) => ({ ...prev, [frame.data.user_id]: frame.data.is_typing }));
      }
    });
    return off;
  }, []);

  const activeConv = conversations.find((c) => c.id === activeId) ?? null;

  const handleSelect = useCallback(
    (id: string) => {
      useChatStore.getState().openConversation(id);
      useChatStore.getState().clearUnread(id);
      navigate(`/chat/${id}`);
      setSidebarOpen(false);
    },
    [navigate],
  );

  const handlePrivateOpened = useCallback(
    (convId: string) => {
      if (convId.startsWith("demo-")) {
        useChatStore.getState().upsertConversation(DEMO_CONVERSATIONS[0]);
      } else {
        chatApi
          .getConversation(convId)
          .then((c) => useChatStore.getState().upsertConversation(c))
          .catch(() => {});
      }
      handleSelect(convId);
    },
    [handleSelect],
  );

  const handleGroupCreated = useCallback(
    (convId: string) => {
      if (convId.startsWith("demo-")) {
        useChatStore.getState().upsertConversation(DEMO_CONVERSATIONS[1]);
      } else {
        chatApi
          .getConversation(convId)
          .then((c) => useChatStore.getState().upsertConversation(c))
          .catch(() => {});
      }
      handleSelect(convId);
    },
    [handleSelect],
  );

  const handleEnterElysia = useCallback(() => {
    if (!elysiaProfile) return;
    chatApi
      .openPrivateConversation(elysiaProfile.user.id)
      .then((conv) => {
        useChatStore.getState().upsertConversation(conv);
        handleSelect(conv.id);
      })
      .catch((e) =>
        setNotice(`进入爱莉会话失败：${e instanceof Error ? e.message : "未知错误"}`),
      );
  }, [elysiaProfile, handleSelect]);

  const handleRecall = useCallback(
    async (msg: ChatMessage) => {
      if (!conversationId || msg.status === "recalled") return;
      try {
        await recallMessage(conversationId, msg.id);
      } catch (e) {
        setNotice(e instanceof Error ? e.message : "撤回失败");
      }
    },
    [conversationId],
  );

  const typingActive = useMemo(
    () => conversationId != null && Object.values(peerTyping).some(Boolean),
    [peerTyping, conversationId],
  );

  const headerTitle = activeConv
    ? activeConv.type === "private"
      ? activeConv.peer?.nickname || activeConv.peer?.username || activeConv.title || "聊天"
      : activeConv.title || "群聊"
    : "聊天";
  const headerSub = activeConv
    ? activeConv.type === "group"
      ? `${activeConv.member_count} 人 · ${activeConv.my_role === "owner" ? "群主" : activeConv.my_role === "admin" ? "管理员" : "成员"}`
      : activeConv.peer?.online
        ? "在线"
        : "离线"
    : "";

  const presenceLabel =
    presenceConnection === "online" ? "在线" : presenceConnection === "connecting" ? "连接中…" : "离线";

  return (
    <div className="chat-page">
      {sidebarOpen && (
        <div className="sidebar-mask" onClick={() => setSidebarOpen(false)} aria-hidden="true" />
      )}
      <aside className={`chat-sidebar ${sidebarOpen ? "open" : ""}`}>
        <div className="chat-sidebar-head">
          <span className="chat-brand">Ayla</span>
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => navigate("/voice")}
            aria-label="打开语音频道"
          >
            语音
          </button>
        </div>
        {demoMode && <div className="demo-banner">演示模式 · 后端未连接</div>}
        {elysiaProfile && <ElysiaEntry profile={elysiaProfile} onEnter={handleEnterElysia} />}
        <ConversationSearch
          currentUserId={currentUser?.id ?? null}
          onPrivateOpened={handlePrivateOpened}
          onGroupCreated={handleGroupCreated}
        />
        <div className="conv-scroll">
          {listLoading && conversations.length === 0 ? (
            <div className="conv-loading">
              <div className="skeleton" style={{ height: 56, marginBottom: 8 }} />
              <div className="skeleton" style={{ height: 56, marginBottom: 8 }} />
              <div className="skeleton" style={{ height: 56 }} />
            </div>
          ) : (
            <ConversationList
              conversations={conversations}
              activeId={activeId}
              elysiaUserId={elysiaProfile?.user.id ?? null}
              onSelect={handleSelect}
            />
          )}
        </div>
        <div className="chat-sidebar-foot">
          <div className="status-line">
            <span className={`status-dot ${presenceConnection}`} />
            连接 {presenceLabel}
          </div>
          <div className="status-line">
            <span className={`status-dot ${backendAlive ? "online" : "offline"}`} />
            后端 {backendAlive === null ? "检测中" : backendAlive ? "正常" : "不可用"}
          </div>
          {currentUser && (
            <button
              type="button"
              className="user-strip"
              onClick={() => navigate("/profile")}
              aria-label="打开个人页"
            >
              <Avatar label={currentUser.nickname || currentUser.username} size={32} online />
              <span className="user-strip-name">
                {currentUser.nickname || currentUser.username}
              </span>
            </button>
          )}
        </div>
      </aside>

      <main className="chat-main">
        {activeConv && conversationId ? (
          <>
            <header className="chat-header">
              <button
                type="button"
                className="msg-action-btn sidebar-toggle"
                onClick={() => setSidebarOpen(true)}
                aria-label="打开会话列表"
              >
                <IconMenu width={16} height={16} />
              </button>
              <div>
                <h3 className="chat-header-title">{headerTitle}</h3>
                {headerSub && <span className="chat-header-sub">{headerSub}</span>}
              </div>
            </header>
            {notice && (
              <div className="chat-notice" role="alert" onClick={() => setNotice(null)}>
                {notice}（点击关闭）
              </div>
            )}
            <MessageList
              messages={messages}
              conversation={activeConv}
              elysiaUserId={elysiaProfile?.user.id ?? null}
              hasMore={bucket?.hasMore ?? false}
              loading={bucket?.loading ?? false}
              onLoadMore={() => {
                if (!conversationId.startsWith("demo-")) {
                  loadMoreHistory(conversationId).catch(() => {});
                }
              }}
              onQuote={setQuote}
              onRecall={(m) => void handleRecall(m)}
            />
            <TypingIndicator typing={typingActive} />
            <MessageInput
              convId={conversationId}
              quote={quote}
              onQuoteClear={() => setQuote(null)}
            />
          </>
        ) : (
          <div className="chat-empty">
            <h2 className="chat-empty-title">选一个会话开始</h2>
            <p className="chat-empty-sub">
              支持私聊 / 群聊 / 图片 / 语音 / 文件 / 引用回复 / 撤回 / 输入中提示
            </p>
            {elysiaProfile && (
              <button type="button" className="btn btn-glow" onClick={handleEnterElysia}>
                和爱莉聊天
              </button>
            )}
          </div>
        )}
      </main>
    </div>
  );
}
