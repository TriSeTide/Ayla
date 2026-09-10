/**
 * GroupChat —— 群内聊天子界面（F3，R-G2）。
 *
 * 复用现有聊天能力（不做侧栏/演示数据/爱莉入口）：MessageList + MessageInput +
 * loadHistory/loadMoreHistory/recallMessage 全复用 hooks/useChat 与 chat/message store。
 * 群 id 即会话 id（GroupPage 传入 groupId）。
 * 群聊已删除「对方正在输入」功能：不订阅 typing 帧、不显示指示、不声明 typing（产品要求）。
 *
 * 子群（群聊子群功能）：
 * - 进入群时拉子群列表，默认选中「默认组」；子群数 > 1 时在输入框上方显示
 *   可左右滑动的选项卡切换栏（窄屏/宽屏一致）；
 * - 切换子群只拉历史；消息实际进入可视区后逐条精确标已读；
 * - MessageList 按当前子群过滤显示（bucket 仍按会话缓存全量消息）。
 */
import { AuroraquaNavHighlight } from "../../components/motion/AuroraquaNavHighlight";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { motion, useIsPresent } from "framer-motion";
import { useNavigate, useSearchParams } from "react-router-dom";
import { ApiError } from "../../api/client";
import { getElysiaProfile } from "../../api/elysia";
import * as chatApi from "../../api/chat";
import type { ChatMessage, ConversationMember, SubGroup } from "../../api/types";
import { MessageInput, type MessageInputHandle } from "../../components/chat/MessageInput";
import { MessageList } from "../../components/chat/MessageList";
import { auroraquaIndicatorTransition, auroraquaPanelOrchestration, disclosureVariants, panelVariants } from "../../components/motion/auroraquaMotion";
import { IconChevronDown, IconChevronUp } from "../../components/icons";
import { loadHistory, loadMoreHistory, loadHistoryUntilSeq, messageInSubgroup, markMessageReadExact, recallMessage, retryOptimistic, removeOptimistic, cancelOptimistic, TARGET_HISTORY_MAX_PAGES } from "../../hooks/useChat";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { useTabPanelMotion } from "../../hooks/useTabPanelMotion";
import { usePanelSwapMotion } from "../../hooks/usePanelSwapMotion";
import { useChatStore } from "../../stores/chat";
import { useHomeStore } from "../../stores/home";
import { useMessageStore } from "../../stores/message";
import { subgroupKey, useSubGroupStore } from "../../stores/subgroup";
import { chatWS } from "../../ws/chat";
import { useSocialPage } from "../../hooks/useSocialPage";

export function GroupChat({ groupId, panelMotion = false }: { groupId: string; panelMotion?: boolean }) {
  const present = useIsPresent();
  const active = !panelMotion || present;
  const selectionId = useId();
  const subgroupPanelId = useId();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const reducedMotion = usePrefersReducedMotion();
  const rootRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => { rootRef.current?.toggleAttribute("inert", !active); }, [active]);
  const subgroupVariants = useMemo(() => disclosureVariants(reducedMotion), [reducedMotion]);
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[groupId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  const subgroupPage = useSocialPage("subgroups", { groupId }, active);
  // 窄屏选项卡默认收起；同一按钮始终持有焦点，展开不重挂输入框。
  const [subgroupsCollapsed, setSubgroupsCollapsed] = useState(true);
  // 长按消息头像 @ 成员 → 通过 ref 调输入框插入 @Token
  const inputRef = useRef<MessageInputHandle>(null);

  // ---- 子群状态（subgroup store） ----
  const subgroups = useSubGroupStore((s) => s.byGroup[groupId] ?? []);
  const activeSubgroupId = useSubGroupStore((s) => s.activeByGroup[groupId] ?? null);
  const unreadByKey = useSubGroupStore((s) => s.unreadByKey);
  const unreadSeqsByKey = useSubGroupStore((s) => s.unreadSeqsByKey);
  const activeSg = useMemo(
    () => subgroups.find((sg) => sg.id === activeSubgroupId) ?? null,
    [activeSubgroupId, subgroups],
  );
  // 收藏消息跳转定位：/group/:id?msg=<messageId>&seq=<seq>&subgroup=<子群id>
  // （subgroup 缺省 = 默认组；私聊跳转经 ChatConversationRoute 重定向时同样携带）。
  const [searchParams] = useSearchParams();
  const jumpMsg = searchParams.get("msg");
  const jumpSeq = searchParams.get("seq");
  const jumpSubgroup = searchParams.get("subgroup");
  const externalJump = useMemo(() => {
    if (!jumpMsg) return null;
    const seq = Number(jumpSeq);
    return {
      messageId: jumpMsg,
      seq: Number.isInteger(seq) && seq > 0 ? seq : 0,
      subgroupId: jumpSubgroup ?? null,
    };
  }, [jumpMsg, jumpSeq, jumpSubgroup]);
  // 跳转目标在指定子群（或默认组）时先切过去：子群切换会重挂载 MessageList，
  // 新实例在子群匹配后执行定位；子群已删除时保持当前视图（跳转自然失败）。
  useEffect(() => {
    if (!jumpMsg) return;
    if (jumpSubgroup != null) {
      if (subgroups.some((sg) => sg.id === jumpSubgroup) && activeSubgroupId !== jumpSubgroup) {
        useSubGroupStore.getState().setActiveSubgroup(groupId, jumpSubgroup);
      }
    } else {
      const defaultGroup = subgroupPage.items.find((item) => item.is_default);
      if (defaultGroup && activeSubgroupId !== defaultGroup.id) {
        useSubGroupStore.getState().setActiveSubgroup(groupId, defaultGroup.id);
      }
    }
  }, [activeSubgroupId, groupId, jumpMsg, jumpSubgroup, subgroupPage.items, subgroups]);
  const subgroupSelection = `${groupId}:${activeSubgroupId ?? "all"}`;
  const selectionInitialized = useRef(activeSubgroupId != null);
  const establishingSelection = !selectionInitialized.current;
  // A render may be replayed by StrictMode before commit. Only the committed
  // selection establishes the baseline; both motion hooks must see this frame
  // as initialization even when the default subgroup arrives asynchronously.
  useLayoutEffect(() => {
    if (activeSubgroupId != null) selectionInitialized.current = true;
  }, [activeSubgroupId]);
  const selectionRevision = useRef({ identity: subgroupSelection, revision: 0 });
  if (selectionRevision.current.identity !== subgroupSelection) {
    selectionRevision.current = { identity: subgroupSelection, revision: selectionRevision.current.revision + 1 };
  }
  const currentSelectionRevision = selectionRevision.current.revision;
  const [settledHistoryRevision, setSettledHistoryRevision] = useState<number | null>(null);
  const hasSelectedMessages = messages.some((message) => messageInSubgroup(message, activeSubgroupId, activeSg?.is_default ?? false));
  // 缓存命中立即播；未命中等当前请求真正落入消息缓存后再播。会话级 loading 会被
  // 不同子群的并发请求共享，不能用它代替这一选择的完成回执；旧请求也不能消费新选择。
  const subgroupMessagesRef = useTabPanelMotion<HTMLDivElement>(
    subgroupSelection,
    ":scope > .message-list",
    active && (hasSelectedMessages || settledHistoryRevision === currentSelectionRevision),
    establishingSelection,
  );
  const subgroupComposerRef = usePanelSwapMotion<HTMLDivElement>(subgroupSelection, ":scope > .composer", active && !establishingSelection);

  // 爱莉身份（U1：群聊爱莉消息专属气泡判定，与 PrivateChatPane/MessagesPage 同数据源）
  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.user?.id ?? null);
      })
      .catch(() => {
        // profile 未初始化/加载失败 → elysiaUserId 保持 null（无爱莉气泡判定）
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const activeConv = useMemo(
    () => conversations.find((c) => c.id === groupId) ?? null,
    [conversations, groupId],
  );

  // The open conversation needs complete unread coordinates, but members stay paged.
  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    void chatApi.getConversationMetadata(groupId).then((conversation) => {
      if (!cancelled) useChatStore.getState().upsertConversation(conversation);
    }).catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [groupId, active, activeConv?.unread_seqs_complete]);
  // 群聊发送者头像/昵称依赖完整成员表：metadata 有意排除 members（后端
  // ConversationMetadataSerializer），会话目录同样为空；这里全量拉取成员分页并
  // 合并进 conversation.members。members_complete=true 后不再重复拉取；拉取失败
  // 只缺头像/昵称，不阻断聊天（不弹错误）。
  useEffect(() => {
    if (!active) return;
    if (activeConv?.members_complete === true) return;
    let cancelled = false;
    (async () => {
      const members: ConversationMember[] = [];
      let cursor: string | null = null;
      do {
        const page = await chatApi.listConversationMembersPage(groupId, { limit: 100, cursor });
        if (cancelled) return;
        members.push(...page.results);
        cursor = page.next_cursor;
      } while (cursor != null);
      if (cancelled) return;
      useChatStore.setState((state) => {
        const current = state.conversations.find((c) => c.id === groupId);
        // conversations 尚未加载该群（如直接 URL 刷新）：等 metadata upsert 后
        // members_complete 变化触发本 effect 重跑再合并。
        if (!current) return state;
        return {
          conversations: state.conversations.map((c) =>
            c.id === groupId ? { ...c, members, members_complete: true } : c,
          ),
        };
      });
    })().catch(() => {
      // 成员加载失败：头像/昵称缺失但聊天可用
    });
    return () => {
      cancelled = true;
    };
  }, [groupId, active, activeConv?.members_complete]);
  useEffect(() => {
    if (activeSubgroupId != null) return;
    const defaultGroup = subgroupPage.items.find((item) => item.is_default);
    if (defaultGroup) useSubGroupStore.getState().setActiveSubgroup(groupId, defaultGroup.id);
  }, [groupId, activeSubgroupId, subgroupPage.items]);

  // 打开群会话 + 当前子群历史：只拉历史和订阅，已读由 MessageList 可视区确认。
  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    const sgId = activeSubgroupId;
    if (sgId == null) return;
    useChatStore.getState().openConversation(groupId);
    useMessageStore.getState().openBucket(groupId);
    chatWS.subscribe([groupId]);
    loadHistory(groupId, undefined, true, sgId, activeSg?.is_default ?? false)
      .then(() => {
        if (!cancelled) {
          setSettledHistoryRevision(currentSelectionRevision);
        }
      })
      .catch((error) => {
        if (!cancelled) handleHistoryError(error);
      });
    return () => {
      cancelled = true;
      // 离开群聊时清 activeId，避免残留导致其他会话 message.new 被误判 markRead
      const store = useChatStore.getState();
      if (store.activeConversationId === groupId) store.closeConversation();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId, activeSubgroupId, active]);

  const handleHistoryError = useCallback((error: unknown) => {
    if (error instanceof ApiError && (error.status === 403 || error.status === 404)) {
      useChatStore.getState().removeConversation(groupId);
      useMessageStore.getState().reset();
      if (useHomeStore.getState().recentGroupId === groupId) {
        useHomeStore.getState().setRecentGroup(null);
      }
      navigate("/group", { replace: true });
    }
  }, [groupId, navigate]);

  const handleRecall = async (msg: ChatMessage) => {
    if (msg.status === "recalled") return;
    try {
      await recallMessage(groupId, msg.id);
    } catch {
      // 撤回失败静默
    }
  };

  // 长按消息头像 → 输入框 @ 该成员
  const handleMentionUser = useCallback((userId: string, name: string) => {
    inputRef.current?.insertMention(userId, name || "群成员");
  }, []);

  // 双击头像 → 戳一戳（轻互动；WS message.poke 回帧负责渲染与置顶排序）
  const handlePoke = useCallback(async (targetUserId: string) => {
    try {
      await chatApi.sendPoke(groupId, targetUserId);
    } catch {
      // 戳一戳失败静默
    }
  }, [groupId]);

  // 切换子群：store 更新 → 历史加载；切换本身不代表消息已被看到。
  const switchSubgroup = useCallback((sg: SubGroup) => {
    if (sg.id === activeSubgroupId) return;
    useSubGroupStore.getState().setActiveSubgroup(groupId, sg.id);
  }, [activeSubgroupId, groupId]);

  const activeUnreadSeqs = activeSg ? unreadSeqsByKey[subgroupKey(groupId, activeSg.id)] ?? [] : undefined;
  const activeUnreadSet = new Set(activeUnreadSeqs);

  // 子群禁言：开启后仅群主/管理员可发言（普通成员输入框禁用）
  const myRole = activeConv?.my_role;
  const isSubgroupMuted =
    activeSg?.muted === true && myRole !== "owner" && myRole !== "admin";

  return (
    <motion.div
      ref={rootRef}
      className={`group-chat${panelMotion ? " chat-motion-panels" : ""}`}
      data-chat-identity={groupId}
      aria-hidden={!active || undefined}
      inherit={false}
      initial={panelMotion && !reducedMotion ? "enter" : false}
      animate={panelMotion ? "center" : undefined}
      exit={panelMotion ? "exit" : undefined}
      variants={panelMotion ? auroraquaPanelOrchestration : undefined}
    >
      <motion.div
        ref={subgroupMessagesRef}
        className="chat-messages-motion"
        data-motion-panel="chat-messages"
        inherit={panelMotion}
        variants={panelMotion ? panelVariants(reducedMotion, "right", "left") : undefined}
      >
      <MessageList
        key={`${groupId}:${activeSubgroupId ?? "all"}`}
        messages={messages}
        conversation={activeConv}
        elysiaUserId={elysiaUserId}
        hasMore={bucket?.hasMore ?? false}
        loading={bucket?.loading ?? false}
        onLoadMore={() =>
          loadMoreHistory(groupId, activeSubgroupId, activeSg?.is_default ?? false).catch((error) => {
            handleHistoryError(error);
            throw error;
          })
        }
        onQuote={setQuote}
        onMarkRead={(m, exact) => active && exact ? markMessageReadExact(groupId, m.id) : undefined}
        onLoadUntilSeq={(targetSeq) => loadHistoryUntilSeq(groupId, targetSeq, TARGET_HISTORY_MAX_PAGES, activeSubgroupId, activeSg?.is_default ?? false).catch(() => false)}
        onRecall={(m) => void handleRecall(m)}
        onRetry={(m) => retryOptimistic(groupId, m)}
        onRemove={(m) => removeOptimistic(groupId, m)}
        onCancel={(m) => cancelOptimistic(groupId, m)}
        onMentionSender={handleMentionUser}
        onPoke={handlePoke}
        subgroupId={activeSubgroupId}
        isDefaultSubgroup={activeSg?.is_default ?? false}
        unreadSeqsOverride={activeUnreadSeqs}
        mentionUnreadSeqsOverride={activeSg ? (activeConv?.mention_unread_seqs ?? []).filter((seq) => activeUnreadSet.has(seq)) : undefined}
        replyUnreadSeqsOverride={activeSg ? (activeConv?.reply_unread_seqs ?? []).filter((seq) => activeUnreadSet.has(seq)) : undefined}
        externalJump={externalJump}
      />
      </motion.div>
      {/* 输入区始终使用同一 DOM；窄屏子群条绝对定位于其顶部，不参与消息列表高度分配。 */}
      <motion.div
        ref={subgroupComposerRef}
        className={`group-chat-compose-area${panelMotion ? " chat-composer-motion" : ""}`}
        data-motion-panel="chat-composer"
        data-subgroup-composer-owner={subgroupSelection}
        inherit={panelMotion}
        variants={panelMotion ? panelVariants(reducedMotion, "bottom") : undefined}
      >
        {isNarrow && Math.max(subgroups.length, subgroupPage.total) > 1 && (
          <div
            className={`group-chat-subgroup-switcher${subgroupsCollapsed ? " is-collapsed" : ""}`}
            // 包含折叠按钮：这一栏内的手势仅操作子群，不传给场景横滑。
            onPointerDownCapture={(e) => e.stopPropagation()}
            onTouchStartCapture={(e) => e.stopPropagation()}
            onTouchMoveCapture={(e) => e.stopPropagation()}
            onTouchEndCapture={(e) => e.stopPropagation()}
            onTouchCancelCapture={(e) => e.stopPropagation()}
          >
            <motion.button
              type="button"
              className={subgroupsCollapsed ? "group-chat-subgroup-collapsed" : "group-chat-subgroup-collapse-btn"}
              onClick={() => setSubgroupsCollapsed((collapsed) => !collapsed)}
              aria-label={subgroupsCollapsed ? "展开子群选项卡" : "收起子群选项卡"}
              aria-expanded={!subgroupsCollapsed}
              aria-controls={subgroupPanelId}
              title={subgroupsCollapsed ? "展开子群" : "收起子群"}
              // 展开/收起时按钮随子群面板同节奏上下移动（复用 disclosure 动画时长/缓动）
              animate={{ y: subgroupsCollapsed ? 0 : -4 }}
              transition={reducedMotion ? { duration: 0 } : auroraquaIndicatorTransition}
            >
              {subgroupsCollapsed ? <IconChevronUp width={14} height={14} /> : <IconChevronDown width={14} height={14} />}
            </motion.button>
            <motion.div
              id={subgroupPanelId}
              className="group-chat-subgroup-panel"
              initial={false}
              animate={subgroupsCollapsed ? "closed" : "open"}
              variants={subgroupVariants}
              style={{ overflow: "hidden", pointerEvents: subgroupsCollapsed ? "none" : undefined }}
            >
              <div
                className="group-chat-subgroup-tabs"
                role="tablist"
                aria-label="子群切换"
                aria-hidden={subgroupsCollapsed}
              >
                {subgroups.map((sg) => {
                  const unread = unreadByKey[subgroupKey(groupId, sg.id)] ?? 0;
                  const active = sg.id === activeSubgroupId;
                  return (
                    <button
                      key={sg.id}
                      type="button"
                      role="tab"
                      aria-selected={active}
                      disabled={subgroupsCollapsed}
                      tabIndex={subgroupsCollapsed ? -1 : undefined}
                      className={`group-chat-subgroup-tab has-auroraqua-highlight${active ? " is-active" : ""}`}
                      onClick={() => switchSubgroup(sg)}
                    >
                      {active && <AuroraquaNavHighlight id={selectionId} />}
                      <span className="group-chat-subgroup-tab-name">{sg.name}</span>
                      {sg.muted === true && (
                        <span className="group-chat-subgroup-tab-muted" title="已禁言（仅群主/管理员可发言）">
                          禁言
                        </span>
                      )}
                      {unread > 0 && (
                        <span className="group-chat-subgroup-tab-badge" aria-label={`${unread} 条未读`}>
                          {unread > 99 ? "99+" : unread}
                        </span>
                      )}
                    </button>
                  );
                })}
                {subgroupPage.hasMore && <button type="button" className="group-chat-subgroup-tab"
                  disabled={subgroupsCollapsed || subgroupPage.loading} tabIndex={subgroupsCollapsed ? -1 : undefined}
                  onClick={() => void subgroupPage.loadMore()}>{subgroupPage.loading ? "加载中…" : "加载更多子群"}</button>}
              </div>
            </motion.div>
          </div>
        )}
        <MessageInput
          ref={inputRef}
          convId={groupId}
          quote={quote}
          onQuoteClear={() => setQuote(null)}
          members={activeConv?.members}
          groupId={groupId}
          groupRole={activeConv?.my_role ?? undefined}
          subgroupId={activeSubgroupId}
          disabled={isSubgroupMuted || !active || activeSubgroupId == null || activeConv?.my_muted === true}
          disabledHint={!active ? undefined
            : activeConv?.my_muted === true ? "你已被禁言" : isSubgroupMuted ? "该子群已禁言，仅群主/管理员可发言" : undefined}
        />
      </motion.div>
    </motion.div>
  );
}
