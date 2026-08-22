/**
 * 全局音频播放互斥（语音消息"同时只能播放一个"）。
 *
 * 每个可播放组件在开始播放前调用 claimAudioPlayback 注册自己的 stop 回调：
 * - 若已有其他实例在播放，先调用旧 stop（暂停 + UI 复位）再替换；
 * - 组件暂停/播完/卸载时调用 releaseAudioPlayback 注销；
 * - 模块级单例，跨所有气泡实例生效（群聊/私聊/多开面板均互斥）。
 */
type StopFn = () => void;

let activeStop: StopFn | null = null;

/** 注册为当前唯一播放者；若已有播放者先将其停止。 */
export function claimAudioPlayback(stop: StopFn): void {
  if (activeStop && activeStop !== stop) {
    try {
      activeStop();
    } catch {
      // 旧实例清理失败不阻塞新播放
    }
  }
  activeStop = stop;
}

/** 注销：仅当自己仍是当前播放者时清空（避免误清新实例）。 */
export function releaseAudioPlayback(stop: StopFn): void {
  if (activeStop === stop) activeStop = null;
}

/** 测试辅助：清空注册表。 */
export function resetAudioPlayback(): void {
  activeStop = null;
}
