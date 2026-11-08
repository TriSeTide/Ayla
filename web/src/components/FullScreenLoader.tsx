/**
 * 全屏加载界面：进入网页 / 浏览器刷新 / 登录后，核心数据预加载完成前覆盖全屏。
 * 品牌 + 转圈直接浮于极光背景之上（无卡片容器）；完成后由调用方切换渲染。
 *
 * 标识（2026-11-07）：Ayla 字标之前加图形标识，**居中在字标上方**——
 * 与其它位置「logo 在 Ayla 前面横向并排」不同，这是加载界面的专属排布。
 * 用透明底 logo.svg（design/brand/logo.svg 的 web 副本）。
 */
export function FullScreenLoader() {
  return (
    <div className="fullscreen-loader" role="status" aria-label="正在加载">
      <img
        className="fullscreen-loader-logo"
        src="${import.meta.env.BASE_URL}brand/logo.svg"
        alt=""
        aria-hidden="true"
      />
      <h1 className="fullscreen-loader-brand">Ayla</h1>
      <span className="loading-spinner loading-spinner--md" aria-hidden="true" />
    </div>
  );
}