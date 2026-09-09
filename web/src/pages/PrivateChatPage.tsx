/**
 * PrivateChatPage —— 私聊聊天界面（路由 /chat/:conversationId，替代原 ChatPage 的私聊窗口）。
 *
 * 窄屏：全屏私聊窗口（返回消息中心 + 消息流 + 输入框；底部无导航栏）+ 全屏右滑返回
 * 手势（方案 §2.6，from:'full'，用户拍板 2026-09-04 全站统一：全屏右滑 + 跟手平移 +
 * 松手返回，底层淡入不再保留）：整页 1:1 跟手右移，松手 >120px 或速度达标滑出返回
 * /messages，否则回弹。
 * 宽屏：左 260px 会话列表侧栏 + 右聊天内容区（需求：与主页侧栏宽度一致的
 * 两列布局，侧栏点其他会话可切换）。
 * 复用 PrivateChatPane 承载聊天内容（数据流与宽屏消息中心右侧一致）。
 * 群聊会话由 ChatConversationRoute 重定向到 /group/:id（GroupPage），本页不承载群聊。
 */
import { useMemo } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useChatStore } from "../stores/chat";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { WideMessagesSidebar } from "../components/chat/WideMessagesSidebar";
import { ConversationTransition } from "../components/motion/ConversationTransition";

export function PrivateChatPage() {
  const { conversationId } = useParams<{ conversationId: string }>();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const conversations = useChatStore((s) => s.conversations);
  // 收藏消息跳转定位：/chat/:id?msg=<messageId>&seq=<seq>（私聊无子群概念）
  const [searchParams] = useSearchParams();
  const externalJump = useMemo(() => {
    const messageId = searchParams.get("msg");
    if (!messageId) return null;
    const seq = Number(searchParams.get("seq"));
    return {
      messageId,
      seq: Number.isInteger(seq) && seq > 0 ? seq : 0,
      subgroupId: null,
    };
  }, [searchParams]);

  if (isNarrow) {
    return (
      <FullScreenSwipeBack
        onBack={() => navigate("/messages")}
        enabled={isNarrow}
      >
        <ConversationTransition identity={`private:${conversationId ?? ""}`}>
          <PrivateChatPane
            conversationId={conversationId ?? ""}
            onBack={() => navigate("/messages")}
            panelMotion
            externalJump={externalJump}
          />
        </ConversationTransition>
      </FullScreenSwipeBack>
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
        <ConversationTransition identity={`private:${conversationId ?? ""}`}>
          <PrivateChatPane conversationId={conversationId ?? ""} panelMotion externalJump={externalJump} />
        </ConversationTransition>
      </div>
    </div>
  );
}
