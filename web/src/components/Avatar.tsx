/**
 * Avatar —— 签名元素「在线光环 Presence Halo」（design.md §6）。
 *
 * - 在线：2.5px 锥形渐变环（--ring-online）；
 * - 爱莉：光环额外带 3.2s 呼吸辉光（唯一常驻动画，prefers-reduced-motion 降级）；
 * - 离线：褪为 --ice-100 灰环；
 * - 色彩不作唯一信息载体：在线状态由调用方同时给文字标签（design.md §10）。
 */
import { useState } from "react";
import type { CSSProperties } from "react";

export function Avatar({
  label,
  size = 40,
  online = false,
  isElysia = false,
  imageUrl,
  style,
}: {
  /** 首字符/缩写（无头像图时展示） */
  label?: string;
  size?: number;
  online?: boolean;
  /** 爱莉专属光环（呼吸辉光），不可复用于普通用户（design.md §8 Don't） */
  isElysia?: boolean;
  imageUrl?: string | null;
  style?: CSSProperties;
}) {
  const [imageFailed, setImageFailed] = useState(false);
  const safeLabel = label?.trim() || "?";
  const fontSize = Math.round(size * 0.42);
  return (
    <span
      className={`avatar-halo ${online ? "" : "is-offline"} ${isElysia && online ? "is-elysia" : ""}`}
      style={{ width: size + 5, height: size + 5, ...style }}
      aria-hidden="true"
    >
      <span
        className={`avatar-core ${isElysia ? "avatar-core-elysia" : "avatar-core-user"}`}
        style={{ fontSize }}
      >
        {imageUrl && !imageFailed ? (
          <img
            src={imageUrl}
            alt=""
            width={size}
            height={size}
            style={{ objectFit: "cover" }}
            onError={() => setImageFailed(true)}
          />
        ) : (
          safeLabel.slice(0, 1)
        )}
      </span>
    </span>
  );
}
