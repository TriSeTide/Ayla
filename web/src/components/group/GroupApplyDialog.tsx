/**
 * GroupApplyDialog —— 群聊申请/加入弹窗（GROUP REQUEST）。
 *
 * 从搜索页（SearchPage）的群申请弹窗抽取复用：视觉与交互完全沿用原实现
 * （group-apply-* 样式），适用于任何「未加入群聊」场景：
 * - 搜索页「申请加入」；
 * - 分享群聊跳转守卫（点击未加入的群分享卡片）；
 * - /group/:id 路由守卫（直接输链接访问未加入的群）。
 *
 * 行为：公开群（join_policy=public）→「直接加入」；申请制/未知 →「发送入群申请」。
 * 公开群直接通过 → onJoined 回调（默认跳转 /group/:id）。
 * portal 挂 document.body（复用层统一，规避父级 backdrop-filter 裁剪）。
 */
import { useState } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import { applyToGroup } from "../../api/chat";

/** 弹窗所需的最小群信息（join_policy 未知时传 null，按申请制文案与流程） */
export interface GroupApplyData {
  id: string;
  title?: string;
  join_policy?: "public" | "application" | null;
}

export function GroupApplyDialog({
  group,
  onClose,
  onJoined,
}: {
  group: GroupApplyData;
  onClose: () => void;
  /** 公开群直接加入成功后的跳转（缺省 = 跳 /group/:id） */
  onJoined?: (conversationId: string) => void;
}) {
  const navigate = useNavigate();
  const isPublicGroup = group.join_policy === "public";
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    if (busy || sent) return;
    setBusy(true);
    setError(null);
    try {
      const response = await applyToGroup(group.id, message.trim());
      if ("conversation_id" in response && response.status === "accepted") {
        if (onJoined) onJoined(response.conversation_id);
        else navigate(`/group/${response.conversation_id}`);
        return;
      }
      setSent(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送入群申请失败");
    } finally {
      setBusy(false);
    }
  };

  return createPortal(
    <div className="group-apply-overlay" onClick={onClose}>
      <div
        className="group-apply-dialog glass-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby="group-apply-title"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="group-apply-head">
          <div>
            <span className="group-apply-kicker">GROUP REQUEST</span>
            <h2 id="group-apply-title">
              {isPublicGroup ? "加入" : "申请加入"}「{group.title?.trim() || "该群聊"}」
            </h2>
          </div>
          <button type="button" className="icon-btn-40" onClick={onClose} aria-label="关闭">×</button>
        </header>
        {sent ? (
          <div className="group-apply-success" role="status">
            <span className="group-apply-success-icon" aria-hidden="true">✓</span>
            <strong>申请已发送</strong>
            <p>等待群主或管理员审核，同意后你就能进入群聊。</p>
            <button type="button" className="btn btn-primary" onClick={onClose}>知道了</button>
          </div>
        ) : (
          <>
            <p className="group-apply-desc">
              {isPublicGroup ? "这是一个公开群聊，点击即可直接加入。" : "这是一个申请制群聊，群主或管理员同意后才能入群。"}
            </p>
            <label className="group-apply-label" htmlFor="group-apply-message">
              给群主留言 <span>（可选）</span>
            </label>
            <textarea
              id="group-apply-message"
              aria-label="给群主留言"
              className="field group-apply-message"
              value={message}
              maxLength={200}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="简单介绍一下自己吧…"
            />
            {error && <p className="group-apply-error" role="alert">{error}</p>}
            <div className="group-apply-actions">
              <button type="button" className="btn btn-ghost" onClick={onClose} disabled={busy}>取消</button>
              <button type="button" className="btn btn-primary" onClick={() => void submit()} disabled={busy}>
                {busy ? (isPublicGroup ? "加入中…" : "发送中…") : (isPublicGroup ? "直接加入" : "发送入群申请")}
              </button>
            </div>
          </>
        )}
      </div>
    </div>,
    document.body,
  );
}
