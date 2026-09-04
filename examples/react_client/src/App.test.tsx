import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const encoder = new TextEncoder();

function sse(events: unknown[]) {
  const payload = [
    ...events.map((event) => `data: ${JSON.stringify(event)}\n\n`),
    "data: [DONE]\n\n",
  ].join("");

  return new Response(
    new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode(payload));
        controller.close();
      },
    }),
    {
      headers: {
        "content-type": "text/event-stream",
        "x-vercel-ai-ui-message-stream": "v1",
      },
    },
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("useChat protocol client", () => {
  it("assembles reasoning, text, tools, sources and data", async () => {
    const fetchMock = vi.fn(async () => sse([
      { type: "start", messageId: "assistant-test", messageMetadata: { traceId: "test" } },
      { type: "start-step" },
      { type: "reasoning-start", id: "reasoning-1" },
      { type: "reasoning-delta", id: "reasoning-1", delta: "Check inputs." },
      { type: "reasoning-end", id: "reasoning-1" },
      { type: "text-start", id: "text-1" },
      { type: "text-delta", id: "text-1", delta: "The stream works." },
      { type: "text-end", id: "text-1" },
      { type: "tool-input-available", toolCallId: "tool-1", toolName: "weather", input: { city: "Tokyo" }, dynamic: true },
      { type: "tool-output-available", toolCallId: "tool-1", output: { celsius: 27 }, dynamic: true },
      { type: "source-url", sourceId: "source-1", url: "https://example.com", title: "Example" },
      { type: "data-progress", id: "progress-1", data: { value: 100 } },
      { type: "finish-step" },
      { type: "finish", finishReason: "stop" },
    ]));
    vi.stubGlobal("fetch", fetchMock);

    render(<App />);
    await userEvent.click(screen.getByTestId("run-complete"));

    await waitFor(() => expect(screen.getByTestId("status")).toHaveTextContent("ready"));
    expect(screen.getByText("The stream works.")).toBeInTheDocument();
    expect(screen.getByText("Check inputs.")).toBeInTheDocument();
    expect(document.querySelector('[data-part-type="dynamic-tool"]')).toHaveTextContent("output-available");
    expect(document.querySelector('[data-part-type="source-url"]')).toBeInTheDocument();
    expect(document.querySelector('[data-part-type="data-progress"]')).toBeInTheDocument();
    expect(screen.getByTestId("event-log")).toHaveTextContent("tool:weather");
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("exposes protocol error events through useChat", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => sse([
      { type: "start", messageId: "assistant-error" },
      { type: "start-step" },
      { type: "error", errorText: "Synthetic provider failure" },
    ])));

    render(<App />);
    await userEvent.click(screen.getByTestId("run-error"));

    await waitFor(() => expect(screen.getByTestId("status")).toHaveTextContent("error"));
    expect(screen.getByRole("alert")).toHaveTextContent("Synthetic provider failure");
    expect(screen.getByTestId("event-log")).toHaveTextContent("error:Synthetic provider failure");
  });

});
