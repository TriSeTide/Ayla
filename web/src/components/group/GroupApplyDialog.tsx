/**
 * GroupApply —— 群聊申请/加入（GROUP REQUEST）。
 *
 * 复用搜索页的群申请弹窗视觉与交互（group-apply-* 样式）：
 * - GroupApplyDialog：全屏弹窗（分享群聊跳转守卫 / 搜索页用；portal 挂 body）；
 * - GroupApplyGate：右侧内容区卡片（/group/:id 路由守卫用——非遮罩形态，
 *   左侧栏仍可自由切换其他群，避免弹窗遮罩拦截点击造成"界面卡死"）；
 * 两者共用 GroupApplyForm（公开群=直接加入；申请制=发送申请；portal 外不重复实现）。
 */
import { useState } from "react";
import { createPortal } from "react-dom";
import { useNavigate } from "react-router-dom";
import { applyToGroup } from "../../api/chat";

/** 弹窗/守卫所需的最小群信息（join_policy 未知时传 null，按申请制文案与流程） */
export interface GroupApplyData {
  id: string;
  title?: string;
  join_policy?: "public" | "application" | null;
  /** 群头像（守卫卡片形态可展示；可选） */
  avatar?: string | null;
}

/** 申请表单主体（无外壳；弹窗/守卫卡片共用） */
export function GroupApplyForm({
  group,
  onDone,
}: {
  group: GroupApplyData;
  /** 公开群直接加入成功后跳转；申请发送成功/取消由调用方自行处理（关闭/留在守卫） */
  onDone: (conversationId: string) => void;
}) {
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
        onDone(response.conversation_id);
        return;
      }
      setSent(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "发送入群申请失败");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="group-apply-form">
      <p className="group-apply-desc">
        {isPublicGroup ? "这是一个公开群聊，点击即可直接加入。" : "这是一个申请制群聊，群主或管理员同意后才能入群。"}
      </p>
      {sent ? (
        <div className="group-apply-success" role="status">
          <span className="group-apply-success-icon" aria-hidden="true">✓</span>
          <strong>申请已发送</strong>
          <p>等待群主或管理员审核，同意后你就能进入群聊。</p>
        </div>
      ) : (
        <>
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
            <button type="button" className="btn btn-primary group-apply-submit" onClick={() => void submit()} disabled={busy}>
              {busy ? (isPublicGroup ? "加入中…" : "发送中…") : (isPublicGroup ? "直接加入" : "发送入群申请")}
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/** 弹窗形态（分享跳转守卫 / 搜索页）：portal + 遮罩，ESC/遮罩关闭 */
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
        <GroupApplyForm
          group={group}
          onDone={(convId) => {
            if (onJoined) onJoined(convId);
            else navigate(`/group/${convId}`);
          }}
        />
      </div>
    </div>,
    document.body,
  );
}

/** 守卫卡片形态（/group/:id 未加入群时右侧内容区渲染；非遮罩，不拦截左侧栏） */
export function GroupApplyGate({
  group,
  onBack,
}: {
  group: GroupApplyData;
  /** 守卫"返回"（如回主页 /group）；公开群直接加入后自动跳群聊 */
  onBack: () => void;
}) {
  const navigate = useNavigate();
  const isPublicGroup = group.join_policy === "public";
  return (
    <div className="group-page-guard">
      <div className="group-apply-gate glass-card" role="dialog" aria-modal="false" aria-labelledby="group-apply-title">
        <header className="group-apply-head">
          <div>
            <span className="group-apply-kicker">GROUP REQUEST</span>
            <h2 id="group-apply-title">
              {isPublicGroup ? "加入" : "申请加入"}「{group.title?.trim() || "该群聊"}」
            </h2>
          </div>
        </header>
        <GroupApplyForm
          group={group}
          onDone={(convId) => navigate(`/group/${convId}`)}
        />
        <div className="group-apply-actions">
          <button type="button" className="btn btn-ghost group-apply-back" onClick={onBack}>返回</button>
        </div>
      </div>
    </div>
  );
}
