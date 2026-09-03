/**
 * ConfirmDialog —— 通用确认对话框（替代 window.confirm，design.md §12.5 弹层规格）。
 *
 * 复用通用弹层容器（.create-sheet-overlay / .create-sheet-card：宽屏居中、
 * 窄屏底部上滑，reduced-motion 关闭动画）；内容为标题 + 描述 + 取消/确认按钮排。
 * ESC 与点击遮罩关闭；挂载自动聚焦「取消」（删除类危险操作，防回车误触确认）。
 * busy 由调用方管理：确认执行期间禁用按钮与关闭路径。
 */
import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { IconClose } from "./icons";

export interface ConfirmDialogProps {
  title: string;
  /** 描述文案（支持多行：white-space: pre-line） */
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  /** 确认执行中：禁用按钮与关闭路径（调用方管理） */
  busy?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}

export function ConfirmDialog({
  title,
  message,
  confirmLabel = "删除",
  cancelLabel = "取消",
  busy = false,
  onConfirm,
  onClose,
}: ConfirmDialogProps) {
  const cancelRef = useRef<HTMLButtonElement>(null);

  // ESC 关闭
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !busy) onClose();
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [busy, onClose]);

  // 自动聚焦取消按钮：危险操作默认焦点给取消，回车不会误删
  useEffect(() => {
    cancelRef.current?.focus();
  }, []);

  // portal 到 body：脱离侧栏/群信息容器的 stacking context（backdrop-filter 会
  // 成为 fixed 后代的 containing block，导致弹窗被容器裁剪/限制）
  return createPortal(
    <div
      className="create-sheet-overlay"
      onClick={(e) => {
        if (e.target === e.currentTarget && !busy) onClose();
      }}
    >
      <div
        className="create-sheet-card confirm-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-dialog-title"
        data-testid="confirm-dialog"
      >
        <header className="create-sheet-head">
          <span className="create-sheet-title" id="confirm-dialog-title">
            {title}
          </span>
          <button
            type="button"
            className="icon-btn-40"
            aria-label="关闭"
            onClick={onClose}
            disabled={busy}
          >
            <IconClose width={18} height={18} />
          </button>
        </header>
        <p className="confirm-dialog-message">{message}</p>
        <div className="confirm-dialog-actions">
          <button
            ref={cancelRef}
            type="button"
            className="btn btn-ghost"
            onClick={onClose}
            disabled={busy}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            className="btn btn-destructive"
            onClick={onConfirm}
            disabled={busy}
          >
            {busy ? "处理中…" : confirmLabel}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
