/**
 * PrivateChatPage —— 私聊聊天界面（路由 /chat/:conversationId，替代原 ChatPage 的私聊窗口）。
 *
 * 窄屏：全屏私聊窗口（返回消息中心 + 消息流 + 输入框；底部无导航栏）+ 左边缘右滑返回
 * 手势（方案 §2.6）：整页 1:1 跟手右移，底层直接复用 /messages 页面本体（NarrowTopBar
 * + MessagesPage）且静止不动（iOS 导航栈 pop 式，用户拍板废弃视差）——拖动露出的就是
 * 返回后的页面，返回零跳变。松手 >120px 或速度达标滑出返回 /messages，否则回弹。
 * 宽屏：左 260px 会话列表侧栏 + 右聊天内容区（需求：与主页侧栏宽度一致的
 * 两列布局，侧栏点其他会话可切换）。
 * 复用 PrivateChatPane 承载聊天内容（数据流与宽屏消息中心右侧一致）。
 * 群聊会话由 ChatConversationRoute 重定向到 /group/:id（GroupPage），本页不承载群聊。
 */
import { motion } from "framer-motion";
import { useNavigate, useParams } from "react-router-dom";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useEdgeSwipeBack } from "../hooks/useEdgeSwipeBack";
import { useChatStore } from "../stores/chat";
import { MessagesPage } from "./MessagesPage";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";

export function PrivateChatPage() {
  const { conversationId } = useParams<{ conversationId: string }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const conversations = useChatStore((s) => s.conversations);

  // 左边缘右滑返回（仅窄屏启用；宽屏分支不接手势）
  const edgeBack = useEdgeSwipeBack({
    onBack: () => navigate("/messages"),
    enabled: isNarrow,
  });

  if (isNarrow) {
    return (
      <div className="private-chat-edge">
        {/* 底层复用 /messages 页面本体（NarrowTopBar + MessagesPage），静止不动
            （iOS 导航栈 pop 式，用户拍板：底层不滑动，原方案 0.3 倍速视差废弃）——
            右滑聊天页滑走，露出即返回后的页面本体，视觉统一、返回零跳变。
            z-index:0 建堆叠上下文（见 private.css 注释）；过渡层对读屏隐藏。 */}
        <div className="private-chat-underlay" aria-hidden="true">
          <NarrowTopBar />
          <div className="private-chat-underlay-body">
            <MessagesPage />
          </div>
        </div>

        {/* 上层聊天面板（1:1 跟手，绑边缘起手手势） */}
        <motion.div
          className="private-chat-overlay"
          style={{ x: edgeBack.x }}
          {...edgeBack.handlers}
        >
          <PrivateChatPane
            key={conversationId}
            conversationId={conversationId ?? ""}
            onBack={() => navigate("/messages")}
          />
        </motion.div>
      </div>
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
