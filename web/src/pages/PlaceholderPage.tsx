/**
 * PlaceholderPage —— F1 路由骨架占位（对应页面由后续 F-step 落地替换）。
 *
 * 空态规格（布局文档 §4）：玻璃卡片 + 一句话 + 步骤标识；不做功能。
 * F2 主页、F6 帖子、F7 桌游、F8 消息、F9 搜索及群内子场景在落地前均渲染此页。
 */
import type { ReactNode } from "react";

export function PlaceholderPage({
  title,
  step,
  description,
  children,
}: {
  title: string;
  /** 预计落地步骤标识（如 "F6"），只作展示 */
  step: string;
  description?: string;
  children?: ReactNode;
}) {
  return (
    <div className="placeholder-page">
      <div className="placeholder-card glass-card">
        <h1 className="placeholder-title">{title}</h1>
        <p className="placeholder-desc">{description ?? `本页面将随 ${step} 步骤落地`}</p>
        <span className="placeholder-step">{step}</span>
        {children}
      </div>
    </div>
  );
}
