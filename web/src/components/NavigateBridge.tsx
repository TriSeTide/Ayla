/**
 * NavigateBridge —— 在 Router 上下文中注册全局导航函数（utils/navigation）。
 *
 * 让无 <Router> 上下文约束的子组件（VoiceMemberRow / PrivateChatPane /
 * MessageList 等，测试中可能被直接渲染）也能在点击头像时跳转个人主页，
 * 而不在渲染期调用 useNavigate（避免 "useNavigate() may be used only in
 * the context of a <Router>"）。
 */
import { useNavigate } from "react-router-dom";
import { registerNavigate } from "../utils/navigation";

export function NavigateBridge() {
  const navigate = useNavigate();
  registerNavigate(navigate);
  return null;
}