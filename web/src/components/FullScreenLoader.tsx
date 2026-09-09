/**
 * 全屏加载界面：进入网页 / 浏览器刷新 / 登录后，核心数据预加载完成前覆盖全屏。
 * 品牌 + 转圈直接浮于极光背景之上（无卡片容器）；完成后由调用方切换渲染。
 */
export function FullScreenLoader() {
  return (
    <div className="fullscreen-loader" role="status" aria-label="正在加载">
      <h1 className="fullscreen-loader-brand">Ayla</h1>
      <span className="loading-spinner loading-spinner--md" aria-hidden="true" />
    </div>
  );
}
