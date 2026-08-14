/**
 * LayoutSwitch —— 主页布局切换开关（卡片 / 列表，需求 R-H4「选择持久化」）。
 *
 * 两个图标按钮：卡片网格 / 列表行；当前项高亮（--ice-500 选中态）。
 * 状态由 home store 持久化（stores/home.ts），本组件只展示与派发切换。
 */
import { IconGrid, IconList } from "../icons";
import type { HomeLayout } from "../../stores/home";

export function LayoutSwitch({
  layout,
  onChange,
}: {
  layout: HomeLayout;
  onChange: (layout: HomeLayout) => void;
}) {
  return (
    <div className="layout-switch" role="group" aria-label="主页布局">
      <button
        type="button"
        className={`layout-switch-btn ${layout === "card" ? "is-active" : ""}`}
        aria-label="卡片布局"
        aria-pressed={layout === "card"}
        onClick={() => onChange("card")}
      >
        <IconGrid width={18} height={18} />
      </button>
      <button
        type="button"
        className={`layout-switch-btn ${layout === "list" ? "is-active" : ""}`}
        aria-label="列表布局"
        aria-pressed={layout === "list"}
        onClick={() => onChange("list")}
      >
        <IconList width={18} height={18} />
      </button>
    </div>
  );
}
