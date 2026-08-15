/**
 * PrivateChatPage —— 私聊聊天界面（路由 /chat/:conversationId，替代原 ChatPage 的私聊窗口）。
 *
 * 窄屏：全屏私聊窗口（返回消息中心 + 消息流 + 输入框；底部无导航栏）。
 * 宽屏：左 260px 会话列表侧栏 + 右聊天内容区（需求：与主页侧栏宽度一致的
 * 两列布局，侧栏点其他会话可切换）。
 * 复用 PrivateChatPane 承载聊天内容（数据流与宽屏消息中心右侧一致）。
 * 群聊会话由 ChatConversationRoute 重定向到 /group/:id（GroupPage），本页不承载群聊。
 */
import { useNavigate, useParams } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useChatStore } from "../stores/chat";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";

export function PrivateChatPage() {
  const { conversationId } = useParams<{ conversationId: string }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const conversations = useChatStore((s) => s.conversations);

  if (isNarrow) {
    return (
      <PrivateChatPane
        key={conversationId}
        conversationId={conversationId ?? ""}
        onBack={() => navigate("/messages")}
      />
    );
  }

  // 宽屏两列：会话列表侧栏 + 当前会话聊天（点击其他会话切换 /chat/:id）
  return (
    <div className="wide-messages">
      <WideMessagesSidebar
        conversations={conversations}
        activeId={conversationId ?? null}
        onSelect={(id) => navigate(`/chat/${id}`)}
      />
      <div className="wide-messages-pane">
        <PrivateChatPane key={conversationId} conversationId={conversationId ?? ""} />
      </div>
    </div>
  );
}
