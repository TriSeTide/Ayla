/**
 * CreateSheet —— FAB 创建浮层（需求：点加号直接开始创建，去掉多动作面板）。
 *
 * 窄屏底部弹出 / 宽屏居中浮层（与建群对话框同构，design.md §12.5 + 弹层规格）。
 * 标题 + 关闭按钮 + 内容（对应场景创建表单：语音/直播/发帖/桌游）。
 * 建群（handler=group）走 GroupCreateDialog 自带浮层，不经过本组件。
 */
import { useEffect } from "react";
import type { ReactNode } from "react";
import { IconClose } from "../components/icons";

export function CreateSheet({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  // ESC 关闭
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  return (
    <div
      className="create-sheet-overlay"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="create-sheet-card" role="dialog" aria-label={title}>
        <header className="create-sheet-head">
          <span className="create-sheet-title">{title}</span>
          <button type="button" className="icon-btn-40" aria-label="关闭" onClick={onClose}>
            <IconClose width={20} height={20} />
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}
