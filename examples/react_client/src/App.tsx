import { useMemo, useState } from "react";
import { useChat } from "@ai-sdk/react";
import {
  DefaultChatTransport,
  type UIMessage,
  type UIMessagePart,
} from "ai";

type Scenario = "complete" | "abort" | "error" | "slow";

function json(value: unknown) {
  return JSON.stringify(value, null, 2);
}

export function PartView({ part }: { part: UIMessagePart<any, any> }) {
  if (part.type === "text") {
    return (
      <article className="part text" data-part-type="text">
        <header>text · {part.state ?? "unknown"}</header>
        <p>{part.text}</p>
      </article>
    );
  }

  if (part.type === "reasoning") {
    return (
      <article className="part reasoning" data-part-type="reasoning">
        <header>reasoning · {part.state ?? "unknown"}</header>
        <p>{part.text}</p>
      </article>
    );
  }

  const record = part as unknown as Record<string, unknown>;
  const state = typeof record.state === "string" ? ` · ${record.state}` : "";

  return (
    <details className="part structured" open data-part-type={part.type}>
      <summary>{part.type}{state}</summary>
      <pre>{json(part)}</pre>
    </details>
  );
}

export function App() {
  const [events, setEvents] = useState<string[]>([]);
  const transport = useMemo(() => new DefaultChatTransport({ api: "/chat" }), []);
  const {
    messages,
    status,
    error,
    sendMessage,
    stop,
    clearError,
  } = useChat({
    transport,
    onData: (part) => setEvents((items) => [...items, `data:${part.type}`]),
    onToolCall: ({ toolCall }) =>
      setEvents((items) => [...items, `tool:${toolCall.toolName}`]),
    onFinish: ({ isAbort, isError, finishReason }) =>
      setEvents((items) => [
        ...items,
        `finish:${finishReason ?? "none"}:abort=${isAbort}:error=${isError}`,
      ]),
    onError: (streamError) =>
      setEvents((items) => [...items, `error:${streamError.message}`]),
  });

  const run = (scenario: Scenario) => {
    if (error) clearError();
    setEvents([`request:${scenario}`]);
    void sendMessage(
      { text: `Run the ${scenario} UI message stream scenario.` },
      { body: { scenario } },
    );
  };

  const busy = status === "submitted" || status === "streaming";

  return (
    <main>
      <header className="hero">
        <p className="eyebrow">protocol verification client</p>
        <h1>Ruby AI events <span>→</span> AI SDK useChat</h1>
        <p>
          Rails emits real SSE frames. This React island delegates parsing,
          accumulation, tool state and cancellation to <code>useChat</code>.
        </p>
      </header>

      <section className="controls" aria-label="Stream scenarios">
        <button data-testid="run-complete" disabled={busy} onClick={() => run("complete")}>
          Run every event
        </button>
        <button data-testid="run-error" disabled={busy} onClick={() => run("error")}>
          Run error path
        </button>
        <button data-testid="run-abort" disabled={busy} onClick={() => run("abort")}>
          Run server abort
        </button>
        <button data-testid="run-slow" disabled={busy} onClick={() => run("slow")}>
          Run slow stream
        </button>
        <button className="secondary" data-testid="stop" disabled={!busy} onClick={() => void stop()}>
          Stop
        </button>
        <output className={`status ${status}`} data-testid="status">{status}</output>
      </section>

      {error && <p className="error" role="alert">{error.message}</p>}

      <section className="grid">
        <div>
          <h2>Rendered parts</h2>
          <div className="messages" data-testid="messages">
            {messages.map((message) => (
              <article className={`message ${message.role}`} key={message.id}>
                <header>{message.role} · {message.id}</header>
                {message.parts.map((part, index) => (
                  <PartView key={`${part.type}-${index}`} part={part} />
                ))}
              </article>
            ))}
          </div>
        </div>

        <aside>
          <h2>useChat state</h2>
          <pre data-testid="parts-json">{json(messages)}</pre>
          <h2>Callbacks</h2>
          <ol data-testid="event-log">
            {events.map((event, index) => <li key={`${event}-${index}`}>{event}</li>)}
          </ol>
        </aside>
      </section>
    </main>
  );
}
