/**
 * useSceneSwipeDirection —— 群内五子场景横滑方向计算（方案 §2.2）。
 *
 * direction 由切换前后 scene 在 GROUP_SCENE_ORDER 的索引差计算：
 * - 1：新场景索引更大（左滑切下一个），新场景从右侧滑入、旧场景向左滑出；
 * - -1：新场景索引更小（右滑切上一个），新场景从左侧滑入、旧场景向右滑出；
 * - 0：索引相同（含 info ↔ chat，二者共享 chat 索引），无横向位移，纯淡入。
 *
 * 抽成纯函数 sceneDirection（可单测）+ hook 绑定（跟踪 activeScene 变化给出
 * 本次切换的方向），供 GroupPage 的 AnimatePresence `custom` 使用。
 */
import { useRef } from "react";
import { GROUP_SCENE_ORDER } from "../stores/group";
import type { GroupScene } from "../stores/group";

/** scene 在五子顺序里的索引；info 不在顺序里，按 chat（居中）处理。 */
export function sceneOrderIndex(scene: GroupScene): number {
  return scene === "info" ? GROUP_SCENE_ORDER.indexOf("chat") : GROUP_SCENE_ORDER.indexOf(scene);
}

/** 由 from→to 的索引差求切换方向。 */
export function sceneDirection(from: GroupScene, to: GroupScene): 1 | -1 | 0 {
  const diff = sceneOrderIndex(to) - sceneOrderIndex(from);
  return diff > 0 ? 1 : diff < 0 ? -1 : 0;
}

/**
 * 跟踪 activeScene 变化，返回"本次切换"的 direction。
 * 挂载首帧（无切换）返回 0；render 阶段更新 ref 是惯用做法（不触发 setState），
 * StrictMode 双跑第二次 prev 已等于 activeScene，direction 不变。
 */
export function useSceneSwipeDirection(activeScene: GroupScene): 1 | -1 | 0 {
  const prevRef = useRef<GroupScene>(activeScene);
  const directionRef = useRef<1 | -1 | 0>(0);
  if (prevRef.current !== activeScene) {
    directionRef.current = sceneDirection(prevRef.current, activeScene);
    prevRef.current = activeScene;
  }
  return directionRef.current;
}
