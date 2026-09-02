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
 * - 切换子群：拉该子群历史 + 标该子群已读（子群未读独立统计）；
 * - MessageList 按当前子群过滤显示（bucket 仍按会话缓存全量消息）。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ApiError } from "../../api/client";
import { getElysiaProfile } from "../../api/elysia";
import * as chatApi from "../../api/chat";
import type { ChatMessage, SubGroup } from "../../api/types";
import { MessageInput, type MessageInputHandle } from "../../components/chat/MessageInput";
import { MessageList } from "../../components/chat/MessageList";
import { IconChevronDown, IconChevronUp } from "../../components/icons";
import { loadHistory, loadMoreHistory, loadHistoryUntilSeq, markConversationReadThrough, markMessageReadExact, markSubgroupRead, recallMessage, retryOptimistic, removeOptimistic, cancelOptimistic, TARGET_HISTORY_MAX_PAGES } from "../../hooks/useChat";
import { NARROW_QUERY, useMediaQuery } from "../../hooks/useMediaQuery";
import { useChatStore } from "../../stores/chat";
import { useHomeStore } from "../../stores/home";
import { useMessageStore } from "../../stores/message";
import { subgroupKey, useSubGroupStore } from "../../stores/subgroup";
import { chatWS } from "../../ws/chat";

export function GroupChat({ groupId }: { groupId: string }) {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const conversations = useChatStore((s) => s.conversations);
  const buckets = useMessageStore((s) => s.buckets);
  const bucket = buckets[groupId];
  const messages = bucket?.messages ?? [];

  const [quote, setQuote] = useState<ChatMessage | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  // 子群列表加载失败：退化为无子群视图（历史按全部消息加载）
  const [subgroupsFailed, setSubgroupsFailed] = useState(false);
  // 窄屏选项卡收起态：默认收起，显示输入框左侧上方的小型半圆按钮
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

  // 进入群：拉子群列表；未选中时默认「默认组」（列表加载完成前不渲染聊天）
  useEffect(() => {
    let cancelled = false;
    chatApi
      .listSubgroups(groupId)
      .then((list) => {
        if (cancelled) return;
        useSubGroupStore.getState().setSubgroups(groupId, list);
        const active = useSubGroupStore.getState().activeByGroup[groupId];
        if (active == null) {
          const defaultSg = list.find((sg) => sg.is_default) ?? list[0];
          useSubGroupStore.getState().setActiveSubgroup(groupId, defaultSg?.id ?? null);
        }
      })
      .catch(() => {
        // 子群列表加载失败：保持无选项卡的默认视图（历史仍按全部消息加载）
        if (!cancelled) {
          setSubgroupsFailed(true);
          useSubGroupStore.getState().setActiveSubgroup(groupId, null);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [groupId]);

  // 打开群会话 + 当前子群历史：拉历史 + 订阅 + 标该子群已读（复用 useChat 数据流）
  useEffect(() => {
    const sgId = activeSubgroupId;
    if (sgId == null && !subgroupsFailed) return;
    useChatStore.getState().openConversation(groupId);
    useMessageStore.getState().openBucket(groupId);
    chatWS.subscribe([groupId]);
    loadHistory(groupId, undefined, true, sgId, activeSg?.is_default ?? false)
      .then(() => {
        setHistoryError(null);
      })
      .catch(handleHistoryError);
    // 打开/切换子群即标该子群已读（子群未读独立统计）
    if (sgId != null) {
      void markSubgroupRead(groupId, sgId).catch(() => {
        // 已读失败保留未读红点，下次切换/进入重试
      });
    }
    return () => {
      // 离开群聊时清 activeId，避免残留导致其他会话 message.new 被误判 markRead
      useChatStore.getState().closeConversation();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groupId, activeSubgroupId]);

  const handleHistoryError = useCallback((error: unknown) => {
    if (error instanceof ApiError && (error.status === 403 || error.status === 404)) {
      useChatStore.getState().removeConversation(groupId);
      useMessageStore.getState().reset();
      if (useHomeStore.getState().recentGroupId === groupId) {
        useHomeStore.getState().setRecentGroup(null);
      }
      navigate("/group", { replace: true });
      return;
    }
    setHistoryError(error instanceof Error ? error.message : "加载聊天记录失败");
  }, [groupId, navigate]);

  const handleRecall = async (msg: ChatMessage) => {
    if (msg.status === "recalled") return;
    try {
      await recallMessage(groupId, msg.id);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "撤回失败");
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
    } catch (e) {
      setNotice(e instanceof Error ? e.message : "戳一戳发送失败");
    }
  }, [groupId]);

  // 切换子群：store 更新 → 历史加载 effect 拉该子群历史 + 标已读
  const switchSubgroup = useCallback((sg: SubGroup) => {
    if (sg.id === activeSubgroupId) return;
    useSubGroupStore.getState().setActiveSubgroup(groupId, sg.id);
  }, [activeSubgroupId, groupId]);

  const activeUnreadSeqs = activeSg ? unreadSeqsByKey[subgroupKey(groupId, activeSg.id)] ?? [] : undefined;

  // 子群禁言：开启后仅群主/管理员可发言（普通成员输入框禁用）
  const myRole = activeConv?.my_role;
  const isSubgroupMuted =
    activeSg?.muted === true && myRole !== "owner" && myRole !== "admin";

  return (
    <div className="group-chat">
      {historyError && (
        <div className="chat-notice" role="alert">
          <span>{historyError}</span>
          <button type="button" className="btn btn-ghost" onClick={() => {
            setHistoryError(null);
            loadHistory(groupId, undefined, true, activeSubgroupId, activeSg?.is_default ?? false)
              .catch(handleHistoryError);
          }}>重试</button>
        </div>
      )}
      {notice && (
        <div className="chat-notice" role="alert" onClick={() => setNotice(null)}>
          {notice}（点击关闭）
        </div>
      )}
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
        onMarkRead={(m, exact) => exact ? markMessageReadExact(groupId, m.id) : undefined}
        onMarkConversationRead={(throughSeq, excluded) => {
          const sgId = activeSubgroupId;
          return sgId != null
            ? markSubgroupRead(groupId, sgId)
            : markConversationReadThrough(groupId, throughSeq, excluded);
        }}
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
        mentionUnreadSeqsOverride={activeSg ? [] : undefined}
        replyUnreadSeqsOverride={activeSg ? [] : undefined}
      />
      {/* 子群选项卡切换栏：仅窄屏显示（宽屏用左侧栏子群列表切换）；可收起为半圆按钮 */}
      {isNarrow && subgroups.length > 1 && (
        subgroupsCollapsed ? (
          <button
            type="button"
            className="group-chat-subgroup-collapsed"
            onClick={() => setSubgroupsCollapsed(false)}
            aria-label="展开子群选项卡"
            title="展开子群"
          >
            <IconChevronUp width={14} height={14} />
          </button>
        ) : (
          <div
            className="group-chat-subgroup-tabs"
            role="tablist"
            aria-label="子群切换"
            // 阻止 pointer/touch 事件冒泡到 GroupPage 场景层：
            // 1) pointerdown 不触发场景横滑 drag；
            // 2) touch 不冒泡到 useTouchAxisGuard（否则其 preventDefault 会拦掉选项卡滚动）。
            // 选项卡栏内左右滑动只滚动选项卡，不触发左右切换界面手势。
            onPointerDownCapture={(e) => e.stopPropagation()}
            onTouchStartCapture={(e) => e.stopPropagation()}
            onTouchMoveCapture={(e) => e.stopPropagation()}
            onTouchEndCapture={(e) => e.stopPropagation()}
            onTouchCancelCapture={(e) => e.stopPropagation()}
          >
            <button
              type="button"
              className="group-chat-subgroup-collapse-btn"
              onClick={() => setSubgroupsCollapsed(true)}
              aria-label="收起子群选项卡"
              title="收起子群"
            >
              <IconChevronDown width={14} height={14} />
            </button>
            {subgroups.map((sg) => {
              const unread = unreadByKey[subgroupKey(groupId, sg.id)] ?? 0;
              const active = sg.id === activeSubgroupId;
              return (
                <button
                  key={sg.id}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  className={`group-chat-subgroup-tab${active ? " is-active" : ""}`}
                  onClick={() => switchSubgroup(sg)}
                >
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
          </div>
        )
      )}
      <MessageInput
        ref={inputRef}
        convId={groupId}
        quote={quote}
        onQuoteClear={() => setQuote(null)}
        members={activeConv?.members}
        subgroupId={activeSubgroupId}
        disabled={isSubgroupMuted}
        disabledHint="该子群已禁言，仅群主/管理员可发言"
      />
    </div>
  );
}
