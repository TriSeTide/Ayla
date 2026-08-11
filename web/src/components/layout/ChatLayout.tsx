/**
 * ChatLayout：左侧会话列表 + 右侧聊天窗口（文档 §2 components/layout/ChatLayout.tsx）。
 */
import type { ReactNode } from "react";

export function ChatLayout({
  sidebar,
  detail,
}: {
  sidebar: ReactNode;
  detail: ReactNode;
}) {
  return (
    <div className="chat-layout">
      <aside className="chat-sidebar">{sidebar}</aside>
      <section className="chat-detail">{detail}</section>
    </div>
  );
}
