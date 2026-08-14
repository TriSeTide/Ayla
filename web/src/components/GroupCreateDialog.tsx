/**
 * GroupCreateDialog —— 建群对话框（R-F3 创建群聊；替代原 ChatPage 侧栏的 ConversationSearch 入口）。
 *
 * 复用 ConversationSearch（搜索用户 → 发起私聊 / 勾选多人建群），初始即展开。
 * 建群成功跳 /group/:id；发起私聊跳 /chat/:id。
 */
import { useNavigate } from "react-router-dom";
import { ConversationSearch } from "./chat/ConversationSearch";
import { IconClose } from "./icons";
import { useAuthStore } from "../stores/auth";

export function GroupCreateDialog({ onClose }: { onClose: () => void }) {
  const navigate = useNavigate();
  const currentUser = useAuthStore((s) => s.currentUser);

  return (
    <div className="group-create-overlay" onClick={onClose}>
      <div className="group-create-dialog glass-card" onClick={(e) => e.stopPropagation()}>
        <header className="group-create-dialog-head">
          <span className="group-create-dialog-title">发起会话 / 建群</span>
          <button type="button" className="icon-btn-40" onClick={onClose} aria-label="关闭">
            <IconClose width={18} height={18} />
          </button>
        </header>
        <ConversationSearch
          currentUserId={currentUser?.id ?? null}
          initialOpen
          onPrivateOpened={(id) => {
            onClose();
            navigate(`/chat/${id}`);
          }}
          onGroupCreated={(id) => {
            onClose();
            navigate(`/group/${id}`);
          }}
        />
      </div>
    </div>
  );
}
