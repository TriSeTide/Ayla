/**
 * ServerRail —— 宽屏服务器栏（design.md §12.3，布局文档 §3.2）。
 *
 * 72px 玻璃列：纵向我的群头像（48px 圆形带光环 + 状态角标），点击切换当前群；
 * 当前群左侧 3px --glow-500 指示条 + 头像微放大；底部「创建群聊」加号按钮。
 *
 * M5 会话管理（需求）：头像左上角置顶小图标（45° 左倾粉色 pin，无圆形底）；
 * 鼠标悬停头像自动展开置顶面板（群名 + 置顶/取消置顶）。
 * 面板用 position:fixed 定位：脱离 .server-rail-list 的 overflow-y:auto 边界，
 * 既不被裁剪也不产生横向滚动条，层级也高于相邻 ChannelSidebar（不受 rail
 * 自身 stacking context 限制）。
 */
import { useRef, useState } from "react";
import * as chatApi from "../api/chat";
import type { ConversationSummary } from "../api/types";
import { useChatStore } from "../stores/chat";
import { Avatar } from "../components/Avatar";
import { IconPin, IconPlus } from "../components/icons";

/** 关闭置顶面板的延迟（鼠标从头像移动到面板的过渡时间，避免提前收起） */
const POP_CLOSE_DELAY_MS = 180;

/** 悬停面板定位数据 */
interface PopAnchor {
  id: string;
  top: number;
  left: number;
}

export function ServerRail({
  groups,
  currentGroupId,
  onSelectGroup,
  onCreateGroup,
  onError,
}: {
  groups: ConversationSummary[];
  currentGroupId: string | null;
  onSelectGroup: (id: string) => void;
  /** 底部加号：创建群聊（打开建群对话框） */
  onCreateGroup: () => void;
  /** 置顶失败提示（父组件错误条）；缺省 alert 兜底 */
  onError?: (message: string) => void;
}) {
  /** 悬停展开置顶面板的锚点（相对铁路坐标，头像右侧） */
  const [anchor, setAnchor] = useState<PopAnchor | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const railRef = useRef<HTMLElement | null>(null);

  const cancelClose = () => {
    if (closeTimer.current) {
      clearTimeout(closeTimer.current);
      closeTimer.current = null;
    }
  };

  const scheduleClose = () => {
    if (anchor == null) return;
    cancelClose();
    closeTimer.current = setTimeout(() => setAnchor(null), POP_CLOSE_DELAY_MS);
  };

  const handleTogglePin = (g: ConversationSummary) => {
    const next = !g.is_pinned;
    setBusyId(g.id);
    chatApi
      .togglePinConversation(g.id, next)
      .then(() => useChatStore.getState().setPin(g.id, next))
      .catch((e) => {
        const msg = e instanceof Error ? e.message : "置顶操作失败";
        if (onError) onError(msg);
        else alert(msg);
      })
      .finally(() => setBusyId(null));
  };

  const hoverGroup = anchor ? groups.find((g) => g.id === anchor.id) ?? null : null;

  return (
    <nav className="server-rail" aria-label="我的群" ref={railRef}>
      <ul className="server-rail-list">
        {groups.map((g) => (
          <li
            key={g.id}
            className={`server-item ${g.id === currentGroupId ? "is-active" : ""}`}
            onMouseEnter={(e) => {
              cancelClose();
              const railRect = railRef.current?.getBoundingClientRect();
              if (!railRect) return;
              const rect = e.currentTarget.getBoundingClientRect();
              setAnchor({
                id: g.id,
                top: rect.top - railRect.top + rect.height / 2,
                left: rect.right - railRect.left + 2,
              });
            }}
            onMouseLeave={scheduleClose}
          >
            <button
              type="button"
              className="server-item-btn"
              onClick={() => onSelectGroup(g.id)}
              aria-label={`切换到群聊 ${g.title}`}
              aria-current={g.id === currentGroupId ? "true" : undefined}
            >
              <span className="server-item-avatar">
                <Avatar label={g.title} size={48} online imageUrl={g.avatar || null} />
                {g.is_pinned && (
                  <span className="server-item-pin" aria-label="已置顶" title="已置顶">
                    <IconPin width={11} height={11} />
                  </span>
                )}
                {g.unread_count > 0 && (
                  <span className="server-item-badge">{g.unread_count > 99 ? "99+" : g.unread_count}</span>
                )}
              </span>
            </button>
          </li>
        ))}
      </ul>
      <div className="server-rail-foot">
        <button
          type="button"
          className="server-create-btn"
          onClick={onCreateGroup}
          aria-label="创建群聊"
          title="创建群聊"
        >
          <IconPlus width={22} height={22} />
        </button>
      </div>
      {anchor && hoverGroup && (
        <div
          className="server-pop"
          role="menu"
          aria-label={`${hoverGroup.title} 置顶操作`}
          style={{ top: anchor.top, left: anchor.left }}
          onMouseEnter={cancelClose}
          onMouseLeave={scheduleClose}
        >
          <span className="server-pop-name">{hoverGroup.title}</span>
          <button
            type="button"
            className="server-pop-action"
            role="menuitem"
            disabled={busyId === hoverGroup.id}
            onClick={() => handleTogglePin(hoverGroup)}
          >
            <IconPin width={14} height={14} />
            {hoverGroup.is_pinned ? "取消置顶" : "置顶"}
          </button>
        </div>
      )}
    </nav>
  );
}