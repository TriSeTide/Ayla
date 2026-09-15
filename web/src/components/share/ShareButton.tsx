/**
 * ShareButton —— 通用分享入口按钮（各界面头部/工具栏复用）。
 * 点击打开 ShareSheet（portal 弹窗，窄屏 60% 下半屏 / 宽屏中央）。
 * 视觉：40px 玻璃圆钮 + 线性分享图标（600ms 扫光、200ms hover/press），
 * 对齐 design.md §4 图标按钮与既有顶栏工具位。
 */
import { useState } from "react";
import type { SharePayload } from "../../api/types";
import { IconShare } from "../icons";
import { ShareSheet } from "../share/ShareSheet";

export function ShareButton({
  payload,
  label = "分享",
  className = "",
}: {
  payload: SharePayload;
  label?: string;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        className={className || "icon-btn-40 share-entry-btn"}
        onClick={() => setOpen(true)}
        aria-label={label}
        title={label}
      >
        <IconShare width={18} height={18} />
      </button>
      {open && <ShareSheet payload={payload} onClose={() => setOpen(false)} />}
    </>
  );
}
