/**
 * 全屏加载界面：进入网页 / 浏览器刷新 / 登录后，核心数据预加载完成前覆盖全屏。
 * 品牌 + 转圈直接浮于极光背景之上（无卡片容器）；完成后由调用方切换渲染。
 *
 * 标识（2026-11-07）：Ayla 字标**居中在字标上方**——与页内其它品牌位
 * 「标识在 Ayla 前面横向并排」不同，这是加载界面的专属排布。
 * 统一走 BrandMark 组件（透明底 logo-max.svg），不手写 <img>：
 * 手写时路径要用 JSX 表达式，写成普通字符串会把字面量 `${...}` 当 URL。
 */
import { BrandMark } from "./BrandMark";

export function FullScreenLoader() {
  return (
    <div className="fullscreen-loader" role="status" aria-label="正在加载">
      <h1 className="fullscreen-loader-brand">
        <BrandMark size={64} />
        <span>Ayla</span>
      </h1>
      <span className="loading-spinner loading-spinner--md" aria-hidden="true" />
    </div>
  );
}