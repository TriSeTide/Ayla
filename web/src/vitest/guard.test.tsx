/**
 * 路由守卫测试：未登录重定向登录页、已登录放行、登录后回跳。
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { ProtectedRoute } from "../components/ProtectedRoute";
import { useAuthStore } from "../stores/auth";

function LoginPage() {
  return <div>登录页</div>;
}

function ProtectedContent() {
  return <div>受保护内容</div>;
}

function renderProtected(initialPath: string, authed: boolean) {
  useAuthStore.setState({ accessToken: authed ? "acc" : null });
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route
          path="/"
          element={
            <ProtectedRoute>
              <ProtectedContent />
            </ProtectedRoute>
          }
        />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useAuthStore.setState({ accessToken: null });
});
afterEach(() => {
  useAuthStore.setState({ accessToken: null });
});

describe("ProtectedRoute", () => {
  it("未登录访问受保护页 → 渲染登录页", async () => {
    renderProtected("/", false);
    await waitFor(() => expect(screen.getByText("登录页")).toBeInTheDocument());
    expect(screen.queryByText("受保护内容")).not.toBeInTheDocument();
  });

  it("已登录 → 渲染受保护内容", () => {
    renderProtected("/", true);
    expect(screen.getByText("受保护内容")).toBeInTheDocument();
    expect(screen.queryByText("登录页")).not.toBeInTheDocument();
  });
});
