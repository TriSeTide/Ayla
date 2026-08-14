/**
 * GroupPage —— 群聊场景容器。
 *
 * F1 桥接版：默认聊天子场景直接复用现有 ChatPage（群 id 即会话 id），
 * 保证「/chat/:conversationId 群聊会话重定向 /group/:id」后聊天能力不断。
 * F3 将本文件演进为真正容器：窄屏底栏上移 + 五子界面滑动；宽屏
 * ServerRail + ChannelSidebar + 内容区三列（开发文档 §2.1/§2.3）。
 */
import { useParams } from "react-router-dom";
import { ChatPage } from "./ChatPage";

export function GroupPage() {
  const { id } = useParams<{ id: string }>();
  return <ChatPage conversationIdOverride={id} />;
}
