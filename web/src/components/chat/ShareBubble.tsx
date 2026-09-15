/**
 * ShareBubble —— type=share 消息的转发卡片（气泡内渲染）。
 *
 * 视觉对齐 design.md（§4 玻璃卡片 / §8 线性 SVG 图标）：
 * - 卡片：--glass-bg + blur 18px + 1px 亮边 + 12px 圆角 + compact 阴影；
 * - 封面：左侧 72px 方形（ResourceImage 签名加载，无封面时渐变占位 + 类型图标）；
 * - 类型图标：线性 SVG 2px（group=IconUsers / voice=IconMic / live=IconVideo /
 *   post=IconPost / boardgame=IconGame / user=IconUser）；
 * - 标题 15px/700 --text-primary 两行省略；副标题 13px --text-secondary 单行省略；
 * - 整卡 = 按钮（≥40px 触达），点击按 resolveShareTarget 异步分流跳转
 *   （群聊内目标在该群有条目 → 群内路径，否则群外路径；2026-09-15 用户定稿），
 *   并携带 state.fromShare=true（群内场景对从分享进入的页面免白名单校验）。
 */
import { useState } from "react";
import { useChatStore } from "../../stores/chat";
import { GroupApplyDialog } from "../group/GroupApplyDialog";
import { useNavigate } from "react-router-dom";
import type { ChatMessage, SharePayload } from "../../api/types";
import { ResourceImage } from "../ResourceImage";
import {
  IconGame,
  IconMic,
  IconPost,
  IconShare,
  IconUser,
  IconUsers,
  IconVideo,
} from "../icons";
import { SHARE_TYPE_LABELS, resolveShareTarget, sharePreviewText } from "../../utils/shareRoutes";

export function ShareTypeIcon({
  shareType,
  size = 16,
}: {
  shareType: SharePayload["share_type"];
  size?: number;
}) {
  const common = { width: size, height: size, "aria-hidden": true as const };
  switch (shareType) {
    case "group":
      return <IconUsers {...common} />;
    case "voice":
      return <IconMic {...common} />;
    case "live":
      return <IconVideo {...common} />;
    case "post":
      return <IconPost {...common} />;
    case "boardgame":
      return <IconGame {...common} />;
    case "user":
      return <IconUser {...common} />;
    default:
      return <IconShare {...common} />;
  }
}

export function ShareBubble({
  message,
  groupId,
}: {
  message: ChatMessage;
  /** 当前会话为群聊时传群 id（分流跳转用）；私聊/其他场景为 null */
  groupId?: string | null;
}) {
  const navigate = useNavigate();
  const [resolving, setResolving] = useState(false);
  // 分享目标为群聊且我未加入 → GROUP REQUEST 弹窗（不跳转）
  const [requestOpen, setRequestOpen] = useState(false);
  const payload = message.share_payload ?? null;
  const cover = payload?.cover || "";
  const title = payload?.title?.trim() || message.content?.trim() || "分享";
  const subtitle = payload?.subtitle?.trim() || "";
  const label = payload ? SHARE_TYPE_LABELS[payload.share_type] : "分享";

  const handleClick = async () => {
    if (resolving) return;
    // 群聊分享守卫：未加入的群不能通过分享卡片跳转进入，弹 GROUP REQUEST 申请弹窗。
    if (payload?.share_type === "group") {
      const mine = useChatStore
        .getState()
        .conversations.some((c) => c.id === String(payload.target_id) && c.type === "group");
      if (!mine) {
        setRequestOpen(true);
        return;
      }
    }
    setResolving(true);
    try {
      const route = await resolveShareTarget(payload, groupId);
      if (route) navigate(route, { state: { fromShare: true } });
    } finally {
      setResolving(false);
    }
  };

  return (
    <>
    <button
      type="button"
      className="share-bubble-card"
      onClick={() => void handleClick()}
      disabled={!payload?.target_id || resolving}
      aria-label={`${label}：${title}，点击打开`}
    >
      {cover ? (
        <ResourceImage
          src={cover}
          alt=""
          className="share-bubble-cover"
          variant="thumb"
          fallback={<ShareCoverFallback label={label} />}
        />
      ) : (
        <ShareCoverFallback label={label} />
      )}
      <span className="share-bubble-meta">
        <span className="share-bubble-title">{title}</span>
        <span className="share-bubble-sub">
          {subtitle ? `${label} · ${subtitle}` : label}
        </span>
      </span>
      <span className="share-bubble-chevron" aria-hidden="true" />
    </button>
      {requestOpen && payload && (
        <GroupApplyDialog
          group={{
            id: String(payload.target_id),
            title: payload.title,
            join_policy:
              payload.extra?.join_policy === "public" || payload.extra?.join_policy === "application"
                ? payload.extra.join_policy
                : null,
          }}
          onClose={() => setRequestOpen(false)}
        />
      )}
    </>
  );
}

function ShareCoverFallback({ label }: { label: string }) {
  return (
    <span className="share-bubble-cover-fallback" aria-hidden="true">
      <ShareTypeIcon shareType={labelToType(label)} size={22} />
    </span>
  );
}

/** 兜底占位图标映射（label 回退时用） */
function labelToType(label: string): SharePayload["share_type"] {
  const entry = (Object.entries(SHARE_TYPE_LABELS) as [SharePayload["share_type"], string][]).find(
    ([, v]) => v === label,
  );
  return entry ? entry[0] : "group";
}

/** 会话列表/引用预览兜底文案（后端缺 preview 时前端使用） */
export function shareFallbackPreview(message: ChatMessage): string {
  return sharePreviewText(message.share_payload, message.content);
}
