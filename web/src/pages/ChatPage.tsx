/**
 * ChatPage：M5-2 主页面（挂在 HomeLayout 的 Outlet，文档 §2 pages/ChatPage.tsx）。
 *
 * 布局：ChatLayout 左（爱莉卡 + 会话列表 + 搜索）/ 右（聊天窗口）。
 *
 * 演示数据兜底（架子阶段）：后端不可用且无任何会话时，注入一条"演示会话"，
 * 保证界面可看、可测、方便后续优化。演示消息来源在 data-demo 标记里可见。
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as chatApi from "../api/chat";
import { getElysiaProfile } from "../api/elysia";
import type { ChatMessage, ElysiaProfile } from "../api/types";
import { ChatLayout } from "../components/layout/ChatLayout";
import { ElysiaProfileCard } from "../components/elysia/ElysiaProfileCard";
import { ConversationList } from "../components/chat/ConversationList";
import { ConversationSearch } from "../components/chat/ConversationSearch";
import { MessageInput } from "../components/chat/MessageInput";
import { MessageList } from "../components/chat/MessageList";
import { TypingIndicator } from "../components/chat/TypingIndicator";
import {
  canRecall,
} from "../components/chat/MessageBubble";
import { loadMoreHistory, markReadLatest, recallMessage } from "../hooks/useChat";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { chatWS } from "../ws/chat";

/** 演示数据（仅列表为空且加载失败时注入，明确标记 demo） */
const DEMO_CONVERSATIONS = [
  {
    id: "demo-1",
    type: "private" as const,
    title: "演示用户",
    announcement: "",
    owner_id: "demo-owner",
    members: [],
    my_role: "member" as const,
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
    type: "group" as const,
    title: "演示群聊",
    announcement: "这是一个演示群，用于预览聊天界面",
    owner_id: "demo-owner",
    members: [],
    my_role: "owner" as const,
    member_count: 3,
    unread_count: 0,
    created_at: new Date().toISOString(),
    peer: null,
  },
];

function demoMessages(convId: string): ChatMessage[] {
  const now = Date.now();
  const mk = (i: number, sender: string, content: string, type: "text" | "image" | "voice" | "file" | "emoji" = "text", minutesAgo = 0): ChatMessage => ({
    id: `${convId}-demo-${i}`,
    conversation_id: convId,
    sender_id: sender,
    type,
    content,
    media_id: null,
    reply_to: null,
    status: "read",
    seq: i,
    created_at: new Date(now - minutesAgo * 60_000).toISOString(),
  });
  if (convId === "demo-1") {
    return [
      mk(1, "demo-peer", "你好，这是演示私聊会话（后端不可用时展示）", "text", 12),
      mk(2, "demo-peer", "你可以试试：发送文本、引用、撤回", "text", 11),
      mk(3, "me", "收到，界面已经能正常操作了", "text", 2),
    ];
  }
  return [
    mk(1, "demo-user-a", "大家好", "text", 30),
    mk(2, "demo-user-b", "欢迎来到演示群", "text", 29),
    mk(3, "demo-user-a", "这是一条图片消息占位", "image", 28),
    mk(4, "demo-user-b", "这是一条语音消息占位", "voice", 27),
    mk(5, "me", "界面预览用", "text", 1),
  ];
}

export function ChatPage() {
  const { conversationId } = useParams();
  const navigate = useNavigate();
  const currentUser = useAuthStore((s) => s.currentUser);
  const conversations = useChatStore((s) => s.conversations);
  const listLoading = useChatStore((s) => s.loading);
  const setConversations = useChatStore((s) => s.setConversations);
  const setLoading = useChatStore((s) => s.setLoading);
  const setError = useChatStore((s) => s.setError);
  const activeId = useChatStore((s) => s.activeConversationId);
  const openConversation = useChatStore((s) => s.openConversation);
  const clearUnread = useChatStore((s) => s.clearUnread);
  const upsertConversation = useChatStore((s) => s.upsertConversation);

  const buckets = useMessageStore((s) => s.buckets);
  const bucket = conversationId ? buckets[conversationId] : undefined;
  const messages = bucket?.messages ?? [];
  const [elysiaProfile, setElysiaProfile] = useState<ElysiaProfile | null>(null);
  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [peerTyping, setPeerTyping] = useState<Record<string, boolean>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [demoMode, setDemoMode] = useState(false);

  // 加载会话列表
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    chatApi
      .listConversations()
      .then((list) => {
        if (cancelled) return;
        if (list.length === 0) {
          // 后端在线但无会话：注入演示会话（架子预览）
          setDemoMode(true);
          setConversations(DEMO_CONVERSATIONS);
        } else {
          setDemoMode(false);
          setConversations(list);
        }
      })
      .catch((e) => {
        if (cancelled) return;
        // 后端不可用：注入演示会话，界面仍可预览
        setDemoMode(true);
        setConversations(DEMO_CONVERSATIONS);
        setNotice(`后端未连接（${e instanceof Error ? e.message : "网络错误"}），当前展示演示数据`);
        setError(null);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 加载爱莉 profile（存在则展示入口卡）
  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaProfile(p.enabled ? p : null);
      })
      .catch(() => {
        // 未配置/不可用：不展示入口卡（不阻塞）
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // 打开会话：拉历史 + 订阅 + 标已读
  useEffect(() => {
    if (!conversationId) return;
    openConversation(conversationId);
    if (conversationId.startsWith("demo-")) {
      // 演示会话：注入演示消息
      useMessageStore.getState().prependHistory(conversationId, demoMessages(conversationId), false);
      clearUnread(conversationId);
    } else {
      loadMoreHistory(conversationId).catch(() => {});
    }
    // 订阅 WS（增量）
    chatWS.subscribe([conversationId]);
    markReadLatest(conversationId).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversationId]);

  // 监听对端 typing 帧
  useEffect(() => {
    const off = chatWS.onFrame((frame) => {
      if (frame.type === "typing") {
        setPeerTyping((prev) => ({
          ...prev,
          [frame.data.user_id]: frame.data.is_typing,
        }));
      }
    });
    return off;
  }, []);

  const activeConv = conversations.find((c) => c.id === activeId) ?? null;

  const handleSelect = useCallback(
    (id: string) => {
      openConversation(id);
      clearUnread(id);
      // 同步 URL 参数（/chat/:conversationId），让 ChatPage 的路由 effect
      // 拿到 conversationId 去加载历史/订阅 WS/标已读；否则发送时拿不到会话 id。
      navigate(`/chat/${id}`);
      if (id.startsWith("demo-")) {
        useMessageStore.getState().prependHistory(id, demoMessages(id), false);
      } else {
        loadMoreHistory(id).catch(() => {});
      }
      chatWS.subscribe([id]);
      markReadLatest(id).catch(() => {});
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [navigate],
  );

  const handlePrivateOpened = useCallback(
    (convId: string) => {
      if (convId.startsWith("demo-")) {
        upsertConversation(DEMO_CONVERSATIONS[0]);
      } else {
        chatApi.getConversation(convId).then(upsertConversation).catch(() => {});
      }
      handleSelect(convId);
    },
    [handleSelect, upsertConversation],
  );

  const handleGroupCreated = useCallback(
    (convId: string) => {
      if (convId.startsWith("demo-")) {
        upsertConversation(DEMO_CONVERSATIONS[1]);
      } else {
        chatApi.getConversation(convId).then(upsertConversation).catch(() => {});
      }
      handleSelect(convId);
    },
    [handleSelect, upsertConversation],
  );

  const handleEnterElysia = useCallback(() => {
    if (!elysiaProfile) return;
    chatApi
      .openPrivateConversation(elysiaProfile.user.id)
      .then((conv) => {
        upsertConversation(conv);
        handleSelect(conv.id);
      })
      .catch((e) => setNotice(`进入爱莉会话失败：${e instanceof Error ? e.message : "未知错误"}`));
  }, [elysiaProfile, upsertConversation, handleSelect]);

  const handleRecall = useCallback(
    async (msg: ChatMessage) => {
      if (!conversationId) return;
      if (msg.status === "recalled") return;
      try {
        await recallMessage(conversationId, msg.id);
        if (msg.sender_id !== currentUser?.id) {
          // 演示模式下本地撤回非自己消息也允许（仅演示），真实后端会拒绝
          useMessageStore.getState().setRecalled(conversationId, msg.id);
        }
      } catch (e) {
        setNotice(e instanceof Error ? e.message : "撤回失败");
      }
    },
    [conversationId, currentUser?.id],
  );

  const typingActive = useMemo(() => {
    if (!conversationId) return false;
    return Object.values(peerTyping).some(Boolean);
  }, [peerTyping, conversationId]);

  const headerTitle = activeConv?.title || "聊天";
  const headerSub = activeConv?.type === "group"
    ? `${activeConv.member_count} 人 · ${activeConv.my_role === "owner" ? "群主" : activeConv.my_role === "admin" ? "管理员" : "成员"}`
    : activeConv?.peer?.online
      ? "在线"
      : "离线";

  return (
    <ChatLayout
      sidebar={
        <div className="chat-sidebar-inner">
          {demoMode && <div className="demo-banner">演示模式 · 后端未连接</div>}
          {elysiaProfile && <ElysiaProfileCard profile={elysiaProfile} onEnter={handleEnterElysia} />}
          <ConversationSearch
            currentUserId={currentUser?.id ?? null}
            onPrivateOpened={handlePrivateOpened}
            onGroupCreated={handleGroupCreated}
          />
          {listLoading && !conversations.length ? (
            <div className="conv-loading">加载会话中…</div>
          ) : (
            <ConversationList
              conversations={conversations}
              activeId={activeId}
              onSelect={handleSelect}
            />
          )}
        </div>
      }
      detail={
        activeConv ? (
          <div className="chat-window">
            <header className="chat-header">
              <div>
                <h3>{headerTitle}</h3>
                <span className="chat-header-sub">{headerSub}</span>
              </div>
            </header>
            {notice && (
              <div className="chat-notice" onClick={() => setNotice(null)}>
                {notice}（点击关闭）
              </div>
            )}
            <MessageList
              messages={messages}
              currentUserId={currentUser?.id ?? null}
              hasMore={bucket?.hasMore ?? false}
              loading={bucket?.loading ?? false}
              onLoadMore={() => {
                if (conversationId && !conversationId.startsWith("demo-")) {
                  loadMoreHistory(conversationId).catch(() => {});
                }
              }}
              onQuote={setQuote}
            />
            <TypingIndicator typing={typingActive} />
            <MessageInput convId={conversationId ?? ""} quote={quote} onQuoteClear={() => setQuote(null)} />
            {!demoMode && (
              <div className="chat-toolbar">
                {messages.some((m) => m.sender_id === currentUser?.id && canRecall(m, currentUser?.id)) && (
                  <span className="toolbar-hint">最近 2 分钟内的消息可撤回</span>
                )}
                <button
                  className="recall-latest"
                  disabled={!conversationId}
                  onClick={() => {
                    const last = [...messages].reverse().find((m) => canRecall(m, currentUser?.id));
                    if (last) void handleRecall(last);
                  }}
                >
                  撤回最新一条
                </button>
              </div>
            )}
          </div>
        ) : (
          <div className="chat-empty">
            <p>选择左侧会话开始聊天</p>
            <p className="chat-empty-sub">支持私聊 / 群聊 / 引用回复 / 撤回 / 输入中提示</p>
          </div>
        )
      }
    />
  );
}
