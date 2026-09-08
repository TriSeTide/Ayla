import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LoginPage } from "../pages/LoginPage";
import { RegisterPage } from "../pages/RegisterPage";
import { ApiError } from "../api/client";

const auth = vi.hoisted(() => ({ login: vi.fn(), register: vi.fn(), isAuthenticated: false }));
vi.mock("../hooks/useAuth", () => ({ useAuth: () => auth }));

function pendingRequest() {
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((_, fail) => { reject = fail; });
  return { promise, reject };
}

beforeEach(() => { vi.clearAllMocks(); });

describe("public authentication forms", () => {
  it("keeps login fields and a retry available after a pending request fails", async () => {
    const pending = pendingRequest();
    auth.login.mockReturnValueOnce(pending.promise).mockRejectedValueOnce(new ApiError(401, "合成凭据错误"));
    const { container } = render(<MemoryRouter><LoginPage /></MemoryRouter>);
    fireEvent.change(screen.getByLabelText("用户名"), { target: { value: " fixture-user " } });
    fireEvent.change(screen.getByLabelText("密码"), { target: { value: "fixture-password" } });
    fireEvent.click(screen.getByRole("button", { name: "登录" }));
    expect(screen.getByRole("button", { name: "登录中…" })).toBeDisabled();
    expect(container.querySelector("form")).toHaveAttribute("aria-busy", "true");
    expect(auth.login).toHaveBeenCalledWith("fixture-user", "fixture-password");
    await act(async () => pending.reject(new ApiError(503, "合成登录暂不可用")));
    expect(screen.getByRole("alert")).toHaveTextContent("合成登录暂不可用");
    expect(screen.getByLabelText("用户名")).toHaveValue(" fixture-user ");
    expect(screen.getByLabelText("密码")).toHaveValue("fixture-password");
    fireEvent.click(screen.getByRole("button", { name: "登录" }));
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("合成凭据错误"));
    expect(auth.login).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("link", { name: "注册" })).toHaveAttribute("href", "/register");
  });

  it("associates registration errors with the invalid fields before any request", () => {
    const { container } = render(<MemoryRouter><RegisterPage /></MemoryRouter>);
    const password = screen.getByLabelText("密码（至少 8 位）");
    const confirm = screen.getByLabelText("确认密码");
    fireEvent.change(password, { target: { value: "short" } });
    fireEvent.change(confirm, { target: { value: "different" } });
    fireEvent.submit(container.querySelector("form")!);
    expect(auth.register).not.toHaveBeenCalled();
    expect(password).toHaveAttribute("aria-invalid", "true");
    expect(password).toHaveAccessibleDescription("密码至少 8 位");
    expect(confirm).toHaveAttribute("aria-invalid", "true");
    expect(confirm).toHaveAccessibleDescription("两次输入的密码不一致");
    expect(screen.getByRole("link", { name: "登录" })).toHaveAttribute("href", "/login");
  });

  it("preserves the registration payload and draft on server failure", async () => {
    const pending = pendingRequest();
    auth.register.mockReturnValueOnce(pending.promise);
    const { container } = render(<MemoryRouter><RegisterPage /></MemoryRouter>);
    fireEvent.change(screen.getByLabelText("用户名"), { target: { value: " fixture-user " } });
    fireEvent.change(screen.getByLabelText("邮箱"), { target: { value: "fixture@example.test" } });
    fireEvent.change(screen.getByLabelText("密码（至少 8 位）"), { target: { value: "fixture-password" } });
    fireEvent.change(screen.getByLabelText("确认密码"), { target: { value: "fixture-password" } });
    fireEvent.click(screen.getByRole("button", { name: "注册" }));
    expect(screen.getByRole("button", { name: "注册中…" })).toBeDisabled();
    expect(container.querySelector("form")).toHaveAttribute("aria-busy", "true");
    expect(auth.register).toHaveBeenCalledWith({
      username: "fixture-user", email: "fixture@example.test", password: "fixture-password", nickname: undefined,
    });
    await act(async () => pending.reject(new ApiError(409, "合成用户名已存在")));
    expect(screen.getByRole("alert")).toHaveTextContent("合成用户名已存在");
    expect(screen.getByLabelText("邮箱")).toHaveValue("fixture@example.test");
    expect(screen.getByLabelText("确认密码")).toHaveValue("fixture-password");
    expect(screen.getByRole("button", { name: "注册" })).toBeEnabled();
  });
});
