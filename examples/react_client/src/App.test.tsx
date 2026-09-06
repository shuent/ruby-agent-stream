import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const encoder = new TextEncoder();
function sse(events: unknown[]) {
  const payload = [...events.map((event) => `data: ${JSON.stringify(event)}\n\n`), "data: [DONE]\n\n"].join("");
  return new Response(new ReadableStream({ start(controller) { controller.enqueue(encoder.encode(payload)); controller.close(); } }), {
    headers: { "content-type": "text/event-stream", "x-vercel-ai-ui-message-stream": "v1" },
  });
}
const successEvents = [
  { type: "start", messageId: "assistant-test" }, { type: "start-step" },
  { type: "data-run", data: { run_id: "run-1", adapter: "openai", model: "gpt-5.6-luna", reasoning_effort: "medium", seed_version: "v1" }, transient: true },
  { type: "reasoning-start", id: "reasoning-1" }, { type: "reasoning-delta", id: "reasoning-1", delta: "在庫と販売を確認します。" }, { type: "reasoning-end", id: "reasoning-1" },
  { type: "tool-input-available", toolCallId: "tool-1", toolName: "search_inventory", input: { skus: [] } },
  { type: "tool-output-available", toolCallId: "tool-1", output: { items: [{ sku: "TEA-GRN", name: "知覧茶", available_stock: 9 }] } },
  { type: "tool-input-available", toolCallId: "tool-2", toolName: "review_sales", input: { skus: [] } },
  { type: "tool-output-available", toolCallId: "tool-2", output: { items: [{ sku: "TEA-GRN", name: "知覧茶", units_sold: 63 }] } },
  { type: "text-start", id: "text-1" }, { type: "text-delta", id: "text-1", delta: "知覧茶を優先してください。" }, { type: "text-end", id: "text-1" },
  { type: "finish-step" }, { type: "finish", finishReason: "stop" },
];
const dashboard = { demo_data: true, revision: "r1", inventory: [], sales: [], suppliers: [], orders: [] };
function mockFetch(events = successEvents) {
  const chat = vi.fn(async () => sse(events));
  let sequence = 0;
  vi.stubGlobal("fetch", vi.fn(async (url: unknown, options?: RequestInit) => {
    if (String(url).startsWith("/chat/")) return chat();
    if (String(url) === "/demo/dashboard") return Response.json(dashboard);
    if (String(url) === "/demo/conversations" && options?.method === "GET") return Response.json([]);
    const body = options?.body ? JSON.parse(String(options.body)) : {};
    return Response.json({ id: `conv-${body.adapter ?? "openai"}-${++sequence}`, adapter: body.adapter ?? "openai", messages: [] });
  }));
  return chat;
}
afterEach(() => { vi.unstubAllGlobals(); sessionStorage.clear(); });

async function openChat() {
  await userEvent.click(screen.getByTestId("nav-chat"));
  return screen.findByTestId("composer");
}

describe("inventory SaaS client", () => {
  it("Enter, Shift+Enter and IME confirmation do not send; button sends once", async () => {
    const chat = mockFetch(); render(<App />);
    const composer = await openChat();
    await userEvent.click(screen.getByTestId("template-予算を確認"));
    await userEvent.type(composer, " 編集済み{Enter}{Shift>}{Enter}{/Shift}");
    fireEvent.compositionStart(composer);
    fireEvent.keyDown(composer, { key: "Enter", code: "Enter", isComposing: true });
    fireEvent.compositionEnd(composer, { data: "確定" });
    expect(chat).not.toHaveBeenCalled();
    expect((composer as HTMLTextAreaElement).value).toContain("編集済み\n\n");
    await userEvent.click(screen.getByTestId("send"));
    await waitFor(() => expect(screen.getByText("知覧茶を優先してください。")).toBeInTheDocument());
    expect(screen.getByTestId("tool-search_inventory")).toHaveTextContent("利用可能 9点");
    expect(chat).toHaveBeenCalledOnce();
    expect(screen.getByTestId("run-meta")).toBeInTheDocument();
    await userEvent.click(screen.getByTestId("new-chat"));
    await waitFor(() => expect(screen.getByTestId("composer")).toHaveValue(""));
    expect(screen.queryByTestId("run-meta")).not.toBeInTheDocument();
    expect(screen.queryByTestId("message-assistant")).not.toBeInTheDocument();
    expect(chat).toHaveBeenCalledOnce();
  });
  it("switches to the API-free DemoModel route", async () => {
    const chat = mockFetch(); render(<App />);
    await userEvent.click(screen.getByTestId("adapter-no-llm-call"));
    await screen.findByTestId("composer");
    await userEvent.type(screen.getByTestId("composer"), "デモを確認");
    await userEvent.click(screen.getByTestId("send"));
    await waitFor(() => expect(chat).toHaveBeenCalledOnce());
    expect((fetch as any).mock.calls.some(([url]: [string]) => url === "/chat/no-llm-call")).toBe(true);
  });
  it("uses standard approval response and automatic continuation", async () => {
    mockFetch();
    const original = fetch;
    const chat = vi.fn().mockResolvedValueOnce(sse([
      { type: "start", messageId: "approval-assistant" }, { type: "start-step" },
      { type: "tool-input-available", toolCallId: "write-1", toolName: "create_replenishment_order", input: { sku: "TEA-GRN", quantity: 60 } },
      { type: "tool-approval-request", approvalId: "approval-1", toolCallId: "write-1" },
      { type: "finish-step" }, { type: "finish", finishReason: "tool-calls" },
    ])).mockResolvedValueOnce(sse([
      { type: "start", messageId: "approval-assistant" }, { type: "start-step" },
      { type: "tool-output-available", toolCallId: "write-1", output: { order: { id: 1, estimated_cost_yen: 45600 } } },
      { type: "finish-step" }, { type: "finish", finishReason: "stop" },
    ]));
    vi.stubGlobal("fetch", vi.fn((url, options) => String(url).startsWith("/chat/") ? chat(url, options) : original(url, options)));
    render(<App />); await openChat(); await userEvent.type(screen.getByTestId("composer"), "登録して"); await userEvent.click(screen.getByTestId("send"));
    await screen.findByTestId("approve"); expect(chat).toHaveBeenCalledOnce();
    await userEvent.click(screen.getByTestId("approve"));
    await screen.findByTestId("order-result");
    expect(chat).toHaveBeenCalledTimes(2);
    const sent = JSON.parse(chat.mock.calls[1][1].body);
    expect(sent.messages.at(-1).parts.find((p: any) => p.approval).state).toBe("approval-responded");
    expect(screen.getAllByTestId("message-assistant")).toHaveLength(1);
  });
});

it("restores session history, isolates switches and starts an empty conversation without sending", async () => {
  const saved = {
    id: "saved", adapter: "openai", title: "保存済みの相談", updated_at: "2026-09-06",
    messages: [
      { id: "user-saved", role: "user", parts: [{ type: "text", text: "保存済みの相談" }] },
      { id: "assistant-saved", role: "assistant", parts: [
        { type: "text", text: "保存済みの回答" },
        { type: "tool-search_inventory", toolCallId: "read", state: "output-available", input: {}, output: { items: [{ sku: "TEA-GRN", available_stock: 9 }] } },
        { type: "tool-create_replenishment_order", toolCallId: "write", state: "approval-requested", input: { sku: "TEA-GRN", quantity: 60 }, approval: { id: "approve-saved" } },
      ] },
    ],
  };
  const conversations = [saved];
  const chat = vi.fn(async () => sse(successEvents));
  vi.stubGlobal("fetch", vi.fn(async (url: unknown, options?: RequestInit) => {
    if (String(url).startsWith("/chat/")) return chat();
    if (url === "/demo/dashboard") return Response.json(dashboard);
    if (url === "/demo/conversations" && options?.method === "POST") {
      const value = { id: "new", adapter: "openai", title: "新しい会話", updated_at: "2026-09-06", messages: [] };
      conversations.unshift(value);
      return Response.json(value);
    }
    if (url === "/demo/conversations") return Response.json(conversations.map(({ messages, ...summary }) => summary));
    return Response.json(conversations.find((c) => String(url).endsWith(c.id)));
  }));
  sessionStorage.setItem("stockroom-conversation", "saved");
  const view = render(<App />);
  await screen.findByText("保存済みの回答");
  expect(screen.getByTestId("tool-search_inventory")).toHaveTextContent("利用可能 9点");
  expect(screen.getByTestId("approve")).toBeInTheDocument();
  expect(screen.getByTestId("composer")).toHaveValue("");
  expect(chat).not.toHaveBeenCalled();
  await userEvent.click(screen.getByTestId("new-chat"));
  await waitFor(() => expect(screen.getByTestId("composer")).toBeEnabled());
  expect(screen.getByTestId("composer")).toHaveValue("");
  expect(screen.queryByTestId("message-user")).not.toBeInTheDocument();
  expect(screen.queryByTestId("tool-search_inventory")).not.toBeInTheDocument();
  expect(screen.queryByTestId("run-meta")).not.toBeInTheDocument();
  expect(screen.getByTestId("send")).toBeDisabled();
  await userEvent.type(screen.getByTestId("composer"), "未送信の下書き");
  await userEvent.click(screen.getByTestId("conversation-saved"));
  await screen.findByText("保存済みの回答");
  expect(screen.getByTestId("composer")).toHaveValue("");
  expect(chat).not.toHaveBeenCalled();
  view.unmount();
  render(<App />);
  await screen.findByText("保存済みの回答");
  expect(screen.getByTestId("approve")).toBeInTheDocument();
  expect(screen.queryByTestId("conversation-new")).not.toBeInTheDocument();
  expect(chat).not.toHaveBeenCalled();
});


it("keeps new chats local until submit and limits the sidebar to ten with a full history page", async () => {
  const conversations = Array.from({ length: 12 }, (_, i) => ({ id: `past-${i}`, adapter: "openai", title: `相談 ${i}`, updated_at: "2026-09-06", messages: [{ id: `u-${i}`, role: "user", parts: [{ type: "text", text: `相談本文 ${i}` }] }] }));
  const create = vi.fn(async () => Response.json({ id: "created", adapter: "openai", messages: [] }));
  const chat = vi.fn(async () => sse(successEvents));
  vi.stubGlobal("fetch", vi.fn(async (url: unknown, options?: RequestInit) => {
    if (String(url).startsWith("/chat/")) return chat();
    if (url === "/demo/dashboard") return Response.json(dashboard);
    if (url === "/demo/conversations" && options?.method === "POST") return create();
    if (url === "/demo/conversations") return Response.json(conversations);
    return Response.json(conversations.find((c) => String(url).endsWith(c.id)));
  }));
  render(<App />);
  await screen.findByTestId("conversation-past-0");
  expect(screen.getByTestId("conversation-list").querySelectorAll("button")).toHaveLength(10);
  expect(screen.queryByTestId("conversation-past-10")).not.toBeInTheDocument();
  for (let i = 0; i < 3; i++) await userEvent.click(screen.getByTestId("new-chat"));
  expect(create).not.toHaveBeenCalled();
  expect(sessionStorage.getItem("stockroom-conversation")).toBeNull();
  expect(screen.getByTestId("composer")).toHaveValue("");
  await userEvent.click(screen.getByTestId("all-conversations"));
  expect(screen.getByTestId("history-page").querySelectorAll("button")).toHaveLength(12);
  await userEvent.click(screen.getByTestId("history-past-11"));
  await screen.findByText("相談本文 11");
  expect(create).not.toHaveBeenCalled();
  await userEvent.click(screen.getByTestId("new-chat"));
  await userEvent.type(screen.getByTestId("composer"), "新規の依頼");
  await userEvent.click(screen.getByTestId("send"));
  await screen.findByText("知覧茶を優先してください。");
  expect(create).toHaveBeenCalledOnce();
  expect(sessionStorage.getItem("stockroom-conversation")).toBe("created");
  await userEvent.type(screen.getByTestId("composer"), "続けて確認");
  await userEvent.click(screen.getByTestId("send"));
  await waitFor(() => expect(chat).toHaveBeenCalledTimes(2));
  expect(create).toHaveBeenCalledOnce();
  const requests = (fetch as any).mock.calls.filter(([url]: [string]) => url.startsWith("/chat/"));
  expect(requests.map(([, options]: [string, RequestInit]) => JSON.parse(String(options.body)).id)).toEqual(["created", "created"]);
});
