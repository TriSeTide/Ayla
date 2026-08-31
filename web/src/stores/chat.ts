/**
 * chat 全局状态：会话列表 + 未读数 + 当前会话（文档 §2 stores/chat.ts）。
 *
 * - conversations：会话列表（来自 GET /chat/conversations/）；
 * - activeConversationId：当前打开的会话；
 * - 未读数：来自会话列表 unread_count + 实时 message.new 增量（未打开会话 +1）；
 * - 打开会话时清空该会话未读。
 */
import { create } from "zustand";
import type {
  ConversationDetail,
  ConversationSummary,
  LastMessagePreview,
} from "../api/types";

/** 归一：ConversationDetail（无 peer）→ ConversationSummary（peer 补 null）
 *  并给 is_pinned/last_message 补默认值（兼容旧后端/旧缓存数据）。 */
function toSummary(conv: ConversationSummary | ConversationDetail): ConversationSummary {
  return {
    ...conv,
    peer: (conv as ConversationSummary).peer ?? null,
    is_pinned: (conv as ConversationSummary).is_pinned ?? false,
    last_message: (conv as ConversationSummary).last_message ?? null,
  };
}

/** 会话排序：置顶优先，置顶组/非置顶组内保持传入顺序（稳定）。 */
function sortConversations(list: ConversationSummary[]): ConversationSummary[] {
  const pinned = list.filter((c) => c.is_pinned);
  const unpinned = list.filter((c) => !c.is_pinned);
  return [...pinned, ...unpinned];
}

interface ChatState {
  conversations: ConversationSummary[];
  loading: boolean;
  error: string | null;
  activeConversationId: string | null;
  lastFetched: number | null;
  /** 群「最近收到新内容」的单调时间戳（ms）。只在收到新内容时 bump，删除/下播/离开不回退。 */
  groupActivityAt: Record<string, number>;
  /** 私信「最近收到新内容」的单调时间戳（ms）。与群 groupActivityAt 平行：
   *  戳一戳/新消息 bump 后私信列表往前排，删除/离开不回退。 */
  conversationActivityAt: Record<string, number>;

  setConversations: (list: ConversationSummary[]) => void;
  /** 收到新内容 → 单调 bump（取 max，避免事件乱序/时钟回退导致卡片往回排）。 */
  bumpGroupActivity: (groupId: string, at?: number) => void;
  /** 私信活跃 bump（单调，语义同 bumpGroupActivity）。 */
  bumpConversationActivity: (convId: string, at?: number) => void;
  upsertConversation: (conv: ConversationSummary | ConversationDetail) => void;
  setLoading: (loading: boolean) => void;
  setError: (err: string | null) => void;
  openConversation: (id: string) => void;
  closeConversation: () => void;
  /** 从会话列表中移除（解散群/退出群/被移除/隐藏删除时），若为当前会话一并置空 */
  removeConversation: (id: string) => void;
  /** 置顶/取消置顶（本人视图），置顶会话排到列表最前 */
  setPin: (convId: string, pinned: boolean) => void;
  /** 更新会话最新一条消息预览（WS message.new 到达时）表达式 */
  setLastMessage: (convId: string, preview: LastMessagePreview) => void;
  /** 收到 message.new → 追加未读序号；无 seq 时保留旧的计数兼容行为。 */
  bumpUnread: (convId: string, details?: { seq?: number; mention?: boolean; reply?: boolean }) => void;
  clearUnread: (convId: string) => void;
  /** 从会话未读序号投影中移除已确认阅读的消息，保留其他特殊未读。 */
  markReadSeqs: (convId: string, seqs: number[]) => void;
  reset: () => void;
}

export const useChatStore = create<ChatState>((set, get) => ({
  conversations: [],
  loading: false,
  error: null,
  activeConversationId: null,
  lastFetched: null,
  groupActivityAt: {},
  conversationActivityAt: {},

  bumpGroupActivity: (groupId, at = Date.now()) =>
    set((state) => {
      const prev = state.groupActivityAt[groupId] ?? 0;
      // 单调：只前进不回退；删除/下播/离开不调用本方法，因此不影响排序。
      if (at <= prev) return state;
      return { groupActivityAt: { ...state.groupActivityAt, [groupId]: at } };
    }),

  bumpConversationActivity: (convId, at = Date.now()) =>
    set((state) => {
      const prev = state.conversationActivityAt[convId] ?? 0;
      // 单调：只前进不回退（与 bumpGroupActivity 同语义）。
      if (at <= prev) return state;
      return { conversationActivityAt: { ...state.conversationActivityAt, [convId]: at } };
    }),

  setConversations: (conversations) => {
    const { conversations: current } = get();
    const sorted = sortConversations(conversations);
    // 并发预加载/页面加载拿到相同数据时不触发无意义重渲染；数据真的变化仍要替换，
    // 否则侧栏会永久保留旧群列表、未读数和头像。
    const same = current.length === sorted.length && current.every((item, index) => {
      const next = sorted[index];
      return item.id === next.id
        && item.title === next.title
        && item.avatar === next.avatar
        && item.unread_count === next.unread_count
        && item.member_count === next.member_count
        && item.is_pinned === next.is_pinned
        && (item.last_message?.seq ?? null) === (next.last_message?.seq ?? null)
        && (item.last_message?.content ?? null) === (next.last_message?.content ?? null);
    });
    if (same && current.length > 0) {
      set({ loading: false, error: null, lastFetched: Date.now() });
      return;
    }
    set({ conversations: sorted, loading: false, error: null, lastFetched: Date.now() });
  },
  upsertConversation: (conv) =>
    set((state) => {
      const normalized = toSummary(conv);
      const exists = state.conversations.some((c) => c.id === normalized.id);
      const conversations = exists
        ? state.conversations.map((c) => (c.id === normalized.id ? { ...c, ...normalized } : c))
        : [normalized, ...state.conversations];
      return { conversations: sortConversations(conversations) };
    }),
  setLoading: (loading) => set({ loading }),
  setError: (error) => set({ error }),

  openConversation: (id) => {
    // 仅记录当前会话；未读必须在服务端已读确认成功后由 clearUnread 清除。
    set({ activeConversationId: id });
  },
  closeConversation: () => set({ activeConversationId: null }),
  removeConversation: (id) =>
    set((state) => ({
      conversations: state.conversations.filter((c) => c.id !== id),
      activeConversationId: state.activeConversationId === id ? null : state.activeConversationId,
    })),

  setPin: (convId, pinned) =>
    set((state) => ({
      conversations: sortConversations(
        state.conversations.map((c) =>
          c.id === convId ? { ...c, is_pinned: pinned } : c,
        ),
      ),
    })),

  setLastMessage: (convId, preview) =>
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === convId ? { ...c, last_message: preview } : c,
      ),
    })),

  bumpUnread: (convId, details) =>
    set((state) => {
      // 旧事件只携带会话 id，保留“当前会话不累加”的历史兼容语义；
      // 新消息事件带 seq 时才进入 F7/F10 的可追踪未读序号投影。
      if (!details && state.activeConversationId === convId) return state;
      return {
        conversations: state.conversations.map((c) => {
          if (c.id !== convId) return c;
        const seq = details?.seq;
        const unreadSeqs = c.unread_seqs ?? [];
        const nextUnread = seq != null && !unreadSeqs.includes(seq)
          ? [...unreadSeqs, seq].sort((a, b) => a - b)
          : unreadSeqs;
        const mentionSeqs = c.mention_unread_seqs ?? [];
        const nextMention = details?.mention && seq != null && !mentionSeqs.includes(seq)
          ? [...mentionSeqs, seq].sort((a, b) => a - b)
          : mentionSeqs;
        const replySeqs = c.reply_unread_seqs ?? [];
        const nextReply = details?.reply && seq != null && !replySeqs.includes(seq)
          ? [...replySeqs, seq].sort((a, b) => a - b)
          : replySeqs;
        return {
          ...c,
          unread_count: seq != null ? nextUnread.length : c.unread_count + 1,
          unread_seqs: seq != null ? nextUnread : c.unread_seqs,
          mention_unread_seqs: seq != null ? nextMention : c.mention_unread_seqs,
          mention_unread_count: seq != null ? nextMention.length : c.mention_unread_count,
          reply_unread_seqs: seq != null ? nextReply : c.reply_unread_seqs,
        };
        }),
      };
    }),

  clearUnread: (convId) =>
    set((state) => ({
      conversations: state.conversations.map((c) =>
        c.id === convId ? { ...c, unread_count: 0 } : c,
      ),
    })),

  markReadSeqs: (convId, seqs) =>
    set((state) => ({
      conversations: state.conversations.map((c) => {
        if (c.id !== convId) return c;
        const read = new Set(seqs);
        const unread = (c.unread_seqs ?? []).filter((seq) => !read.has(seq));
        const mention = (c.mention_unread_seqs ?? []).filter((seq) => !read.has(seq));
        const reply = (c.reply_unread_seqs ?? []).filter((seq) => !read.has(seq));
        return {
          ...c,
          unread_count: unread.length,
          unread_seqs: unread,
          mention_unread_count: mention.length,
          mention_unread_seqs: mention,
          reply_unread_seqs: reply,
        };
      }),
    })),

  reset: () =>
    set({ conversations: [], loading: false, error: null, activeConversationId: null, lastFetched: null, groupActivityAt: {}, conversationActivityAt: {} }),
}));

/** 私信列表按「最近活跃」排序：置顶优先 → 活跃时间新→旧 → 保持原顺序（稳定）。
 *  活跃时间戳由 bumpConversationActivity 单调维护（戳一戳/新消息 bump）。 */
export function sortPrivateByActivity<T extends { id: string; is_pinned?: boolean }>(
  list: T[],
  activityAt: Record<string, number>,
): T[] {
  return [...list].sort((a, b) => {
    const pinnedA = a.is_pinned ?? false;
    const pinnedB = b.is_pinned ?? false;
    if (pinnedA !== pinnedB) return Number(pinnedB) - Number(pinnedA);
    const tsA = activityAt[a.id] ?? 0;
    const tsB = activityAt[b.id] ?? 0;
    if (tsA !== tsB) return tsB - tsA;
    return 0; // 稳定排序：同活跃度保持传入顺序
  });
}

/** 判断 chat store 数据是否过期（默认 60 秒） */
export function isChatStale(maxAgeMs = 60_000): boolean {
  const { lastFetched } = useChatStore.getState();
  if (!lastFetched) return true;
  return Date.now() - lastFetched > maxAgeMs;
}
