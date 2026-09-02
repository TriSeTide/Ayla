/**
 * SubGroupDialog —— 添加/编辑子群弹窗（宽屏侧栏与窄屏群信息共用交互）。
 *
 * - add：输入子群名 + 取消/确定；
 * - edit：预填当前名，可改名；「禁言开关」（开启后仅群主/管理员可发言）；
 *   「删除」按钮（默认组禁用）→ 由调用方二次确认后删除。
 */
import { useState } from "react";
import { createPortal } from "react-dom";
import type { SubGroup } from "../../api/types";
import { IconClose } from "../icons";

export type SubGroupDialogState =
  | { kind: "add" }
  | { kind: "edit"; sg: SubGroup }
  | null;

export function SubGroupDialog({
  state,
  busy,
  error,
  onClose,
  onConfirm,
  onDelete,
}: {
  state: { kind: "add" } | { kind: "edit"; sg: SubGroup };
  busy: boolean;
  error: string | null;
  onClose: () => void;
  /** edit 模式第二个参数为禁言开关当前值（add 模式为 undefined） */
  onConfirm: (name: string, muted?: boolean) => void | Promise<void>;
  onDelete: () => void;
}) {
  const [name, setName] = useState(state.kind === "edit" ? state.sg.name : "");
  const [muted, setMuted] = useState(state.kind === "edit" ? (state.sg.muted ?? false) : false);
  const isEdit = state.kind === "edit";
  const canDelete = isEdit && !state.sg.is_default;

  // portal 到 body：脱离侧栏/群信息容器的 stacking context（backdrop-filter 会
  // 成为 fixed 后代的 containing block，导致弹窗被容器裁剪）
  return createPortal(
    <div className="subgroup-dialog-overlay" onClick={busy ? undefined : onClose}>
      <div
        className="subgroup-dialog glass-card"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-label={isEdit ? "编辑子群" : "添加子群"}
      >
        <header className="subgroup-dialog-head">
          <span className="subgroup-dialog-title">{isEdit ? "编辑子群" : "添加子群"}</span>
          <button type="button" className="icon-btn-40" onClick={onClose} aria-label="关闭" disabled={busy}>
            <IconClose width={18} height={18} />
          </button>
        </header>
        <input
          className="field"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="子群群名"
          aria-label="子群群名"
          maxLength={64}
          autoFocus
        />
        {isEdit && (
          <label className="subgroup-dialog-mute">
            <input
              type="checkbox"
              checked={muted}
              onChange={(e) => setMuted(e.target.checked)}
              disabled={busy}
            />
            <span className="subgroup-dialog-mute-copy">
              <span className="subgroup-dialog-mute-title">禁言该子群</span>
              <span className="subgroup-dialog-mute-desc">开启后仅群主/管理员可发言</span>
            </span>
          </label>
        )}
        {error && <p className="subgroup-dialog-error" role="alert">{error}</p>}
        <div className="subgroup-dialog-actions">
          {isEdit && (
            <button
              type="button"
              className="btn btn-destructive"
              onClick={onDelete}
              disabled={busy || !canDelete}
              title={canDelete ? undefined : "默认组不可删除"}
            >
              删除
            </button>
          )}
          <button type="button" className="btn btn-ghost" onClick={onClose} disabled={busy}>
            取消
          </button>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => {
              const trimmed = name.trim();
              if (!trimmed) return;
              void onConfirm(trimmed, isEdit ? muted : undefined);
            }}
            disabled={busy || !name.trim()}
          >
            {busy ? "保存中…" : "确定"}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
