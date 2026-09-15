/**
 * ShareSheet —— 分享弹窗（design.md §12.5 弹层规格 + §12.8.1 CreateSheet 同族）。
 *
 * - portal 到 document.body（规避父级 backdrop-filter stacking context 裁剪 fixed 弹层）；
 * - 选项卡「群聊 / 私信」：选中胶囊 300ms 滑动 + 内容过渡；
 * - 群聊列表 = 我加入的群（含未读数）；群项子群数 > 1 时点击展开子群列表，选中子群后发送；
 *   子群仅 1 个（默认组）时点击群项直接发送；
 * - 私信列表 = 私聊会话（含自己）；
 * - 发送：sendMessage({ type:"share", content, share_payload, subgroup_id })，成功即关弹窗；
 * - 窄屏（≤768px）：60% 高度下半屏上滑弹窗（250ms ease-out、上沿 24px 圆角、safe-area）；
 *   宽屏：中央 modal（min(480px,100%)、--glass-bg-strong、20px 圆角、--glass-shadow-modal）；
 *   遮罩 rgba(70,91,146,0.25)；ESC/遮罩点击关闭；prefers-reduced-motion 关闭位移。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AnimatePresence, motion } from "framer-motion";
import * as chatApi from "../../api/chat";
import type { ConversationSummary, SharePayload, SubGroup } from "../../api/types";
import { useSocialPage } from "../../hooks/useSocialPage";
import { useAuthStore } from "../../stores/auth";
import { Avatar } from "../Avatar";
import { DirectoryLoadMore } from "../DirectoryLoadMore";
import { IconChevronDown, IconChevronRight, IconClose, IconShare } from "../icons";

/** design.md §7 ease（framer-motion cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

function isNarrow(): boolean {
  return typeof window === "undefined" || window.innerWidth <= 768;
}

export function ShareSheet({
  payload,
  onClose,
}: {
  payload: SharePayload;
  onClose: () => void;
}) {
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  const [tab, setTab] = useState<"group" | "private">("group");
  const [expanded, setExpanded] = useState<{ convId: string; subgroups: SubGroup[] | null } | null>(null);
  const [subLoading, setSubLoading] = useState(false);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const closedRef = useRef(false);

  const groupPage = useSocialPage("conversations", { type: "group" });
  const privatePage = useSocialPage("conversations", { type: "private" });

  // ESC 关闭
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !closedRef.current) onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const close = useCallback(() => {
    if (closedRef.current) return;
    closedRef.current = true;
    onClose();
  }, [onClose]);

  /** 展开/收起某群的子群列表（惰性加载） */
  const toggleSubgroups = useCallback(
    async (convId: string, expandedNow: boolean) => {
      if (expandedNow) {
        setExpanded(null);
        return;
      }
      setExpanded({ convId, subgroups: null });
      setSubLoading(true);
      setError(null);
      try {
        const subs = await chatApi.listSubgroups(convId);
        setExpanded({ convId, subgroups: subs });
      } catch (e) {
        setError(e instanceof Error ? e.message : "子群加载失败");
        setExpanded(null);
      } finally {
        setSubLoading(false);
      }
    },
    [],
  );

  const pickSubgroup = useCallback(
    async (convId: string, subgroupId: number | null, title: string) => {
      if (sending || closedRef.current) return;
      setSending(true);
      setError(null);
      try {
        await chatApi.sendMessage(convId, {
          type: "share",
          content: `[分享]${payload.title || title}`,
          share_payload: payload,
          subgroup_id: subgroupId ?? undefined,
        });
        close();
      } catch (e) {
        setError(e instanceof Error ? e.message : "发送失败");
      } finally {
        setSending(false);
      }
    },
    [sending, payload, close],
  );

  /** 点击群项：子群 >1 展开选择；否则直接发送（默认组） */
  const onGroupClick = async (conv: ConversationSummary) => {
    if (expanded?.convId === conv.id) {
      void toggleSubgroups(conv.id, true);
      return;
    }
    setExpanded(null);
    setError(null);
    setSubLoading(true);
    try {
      const subs = await chatApi.listSubgroups(conv.id);
      if (subs.length > 1) {
        setExpanded({ convId: conv.id, subgroups: subs });
      } else {
        await pickSubgroup(conv.id, null, conv.title);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送失败");
    } finally {
      setSubLoading(false);
    }
  };

  const privateTitle = (conv: ConversationSummary) => conv.peer?.nickname || conv.peer?.username || conv.title || "私聊";

  const renderGroupItem = (conv: ConversationSummary) => {
    const isOpen = expanded?.convId === conv.id;
    return (
      <li key={conv.id} className="share-sheet-item">
        <button
          type="button"
          className="share-sheet-row"
          onClick={() => void onGroupClick(conv)}
          disabled={sending || subLoading}
          aria-label={`分享到群聊 ${conv.title}`}
        >
          <Avatar imageUrl={conv.avatar || null} label={conv.title} size={32} />
          <span className="share-sheet-row-main">
            <span className="share-sheet-row-title">{conv.title}</span>
            {conv.unread_count > 0 && (
              <span className="share-sheet-unread">{conv.unread_count > 99 ? "99+" : conv.unread_count}</span>
            )}
          </span>
          {isOpen ? <IconChevronDown width={16} height={16} /> : <IconChevronRight width={16} height={16} />}
        </button>
        {isOpen && (
          <ul className="share-sheet-subgroups" aria-label={`${conv.title} 的子群`}>
            {(expanded?.subgroups ?? []).map((sg) => (
              <li key={sg.id}>
                <button
                  type="button"
                  className="share-sheet-subgroup"
                  onClick={() => void pickSubgroup(conv.id, Number(sg.id), `${conv.title} · ${sg.name}`)}
                  disabled={sending}
                  aria-label={`分享到 ${conv.title} 的 ${sg.name}`}
                >
                  <span className="share-sheet-subgroup-dot" aria-hidden="true" />
                  <span className="share-sheet-row-title">{sg.name}</span>
                  {sg.is_default && <span className="share-sheet-subgroup-tag">默认</span>}
                </button>
              </li>
            ))}
            {expanded?.subgroups?.length === 0 && <li className="share-sheet-empty-row">该群暂无子群</li>}
          </ul>
        )}
      </li>
    );
  };

  const renderPrivateItem = (conv: ConversationSummary) => {
    const isSelf = conv.peer && currentUserId != null && conv.peer.id === currentUserId;
    const displayName = isSelf ? "我" : privateTitle(conv);
    const avatarSrc = conv.peer?.avatar || null;
    return (
      <li key={conv.id}>
        <button
          type="button"
          className="share-sheet-row"
          onClick={() => void pickSubgroup(conv.id, null, displayName)}
          disabled={sending}
          aria-label={`分享给 ${displayName}`}
        >
          <Avatar imageUrl={avatarSrc} label={displayName} size={32} />
          <span className="share-sheet-row-main">
            <span className="share-sheet-row-title">{displayName}</span>
            {conv.unread_count > 0 && (
              <span className="share-sheet-unread">{conv.unread_count > 99 ? "99+" : conv.unread_count}</span>
            )}
          </span>
        </button>
      </li>
    );
  };

  const list = tab === "group" ? groupPage : privatePage;
  const reduced = prefersReducedMotion();
  const narrow = isNarrow();

  return createPortal(
    <AnimatePresence>
      <motion.div
        className="share-sheet-overlay"
        onClick={close}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: 0.2 }}
      >
        <motion.div
          role="dialog"
          aria-label="选择分享目标"
          className={`share-sheet-card${narrow ? " is-narrow" : ""}`}
          onClick={(e) => e.stopPropagation()}
          initial={
            reduced
              ? { opacity: 0 }
              : narrow
                ? { y: "100%" }
                : { opacity: 0, scale: 0.96, y: 12 }
          }
          animate={
            reduced
              ? { opacity: 1 }
              : narrow
                ? { y: 0 }
                : { opacity: 1, scale: 1, y: 0 }
          }
          exit={
            reduced
              ? { opacity: 0 }
              : narrow
                ? { y: "100%" }
                : { opacity: 0, scale: 0.96, y: 12 }
          }
          transition={{ duration: 0.25, ease: EASE_OUT }}
        >
          <header className="share-sheet-head">
            <span className="share-sheet-title">
              <IconShare width={18} height={18} />
              分享
            </span>
            <button type="button" className="icon-btn-40" onClick={close} aria-label="关闭">
              <IconClose width={18} height={18} />
            </button>
          </header>

          <div className="share-sheet-preview">
            <SharePreview payload={payload} />
          </div>

          <div className="share-sheet-tabs" role="tablist" aria-label="分享目标类型">
            <button
              type="button"
              role="tab"
              aria-selected={tab === "group"}
              className={`share-sheet-tab${tab === "group" ? " is-active" : ""}`}
              onClick={() => setTab("group")}
            >
              群聊
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={tab === "private"}
              className={`share-sheet-tab${tab === "private" ? " is-active" : ""}`}
              onClick={() => setTab("private")}
            >
              私信
            </button>
          </div>

          <div className="share-sheet-body">
            {list.loading ? (
              <div className="share-sheet-state" role="status">
                <span className="loading-spinner loading-spinner--md" />
                加载中…
              </div>
            ) : list.error ? (
              <div className="share-sheet-state">
                <span className="share-sheet-error-text">加载失败：{list.error}</span>
                <button type="button" className="btn btn-ghost" onClick={() => list.refresh()}>
                  重试
                </button>
              </div>
            ) : list.items.length === 0 ? (
              <div className="share-sheet-state">暂无{tab === "group" ? "群聊" : "私信"}</div>
            ) : (
              <ul className="share-sheet-list">
                {list.items.map((c) => (tab === "group" ? renderGroupItem(c) : renderPrivateItem(c)))}
              </ul>
            )}
            {<DirectoryLoadMore {...list} retainCompletedSpace={false} />}
          </div>

          {error && <div className="share-sheet-error">{error}</div>}
        </motion.div>
      </motion.div>
    </AnimatePresence>,
    document.body,
  );
}

/** 弹窗顶部：本次要分享的内容摘要（封面/类型/标题） */
function SharePreview({ payload }: { payload: SharePayload }) {
  return (
    <span className="share-sheet-preview-inner">
      <span className="share-sheet-preview-icon" aria-hidden="true">
        <IconShare width={16} height={16} />
      </span>
      <span className="share-sheet-preview-text" title={payload.title}>
        {payload.title || "分享"}
      </span>
    </span>
  );
}
