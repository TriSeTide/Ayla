import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { MessageInput } from "../components/chat/MessageInput";
import * as chatHook from "../hooks/useChat";

vi.mock("../hooks/useTyping", () => ({ useTyping: () => ({ onInput: vi.fn() }) }));

describe("MessageInput 发送失败重试", () => {
  it("重试复用同一幂等键", async () => {
    const send = vi.spyOn(chatHook, "sendMessage")
      .mockRejectedValueOnce(new Error("网络失败"))
      .mockResolvedValueOnce({
        id: "m1", conversation_id: "c1", sender_id: "u1", type: "text", content: "你好",
        media_id: null, reply_to: null, status: "sent", seq: 1, created_at: new Date().toISOString(),
      });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByPlaceholderText(/输入消息/);
    fireEvent.change(input, { target: { value: "你好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await screen.findByRole("alert");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(2));
    expect(send.mock.calls[0][2]?.idempotencyKey).toBe(send.mock.calls[1][2]?.idempotencyKey);
  });
});
