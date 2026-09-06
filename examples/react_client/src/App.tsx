import { useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent } from "react";
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport, lastAssistantMessageIsCompleteWithApprovalResponses, type UIMessage, type UIMessagePart } from "ai";
import { asToolOutput, templates, toolName, getDashboard, listConversations, getConversation, startConversation, resetDemo, sessionHeaders, type ConversationSummary, type Conversation, type Dashboard, type ApprovalDecision, type Adapter, type RunData } from "./domain";

const labels: Record<string, string> = {
  search_inventory: "在庫", review_sales: "販売実績",
  check_supplier_terms: "仕入条件", calculate_replenishment: "補充提案", create_replenishment_order: "補充発注の登録",
};

function money(value: unknown) {
  return typeof value === "number" ? `${value.toLocaleString("ja-JP")}円` : "—";
}

function ToolCard({ part, onApproval, busy }: PartProps) {
  const name = toolName(part) ?? "unknown";
  const record = part as any;
  const output = asToolOutput(record.output);
  const rows = output?.proposals ?? output?.items ?? [];
  const pending = !["output-available", "output-error", "output-denied"].includes(record.state);

  return (
    <section className={`tool-card ${pending ? "pending" : "done"}`} data-testid={`tool-${name}`}>
      <header><span>{labels[name] ?? name}</span><small>{record.state === "approval-requested" ? "承認待ち" : record.state === "approval-responded" ? "判断を保存中…" : record.state === "output-denied" ? "拒否済み" : name === "create_replenishment_order" && record.state === "output-available" ? "登録完了" : pending ? "ツール実行中…" : `${rows.length}件取得`}</small></header>
      {name === "create_replenishment_order" && <p>SKU: <strong>{record.input?.sku}</strong> · {record.input?.quantity}点</p>}
      {record.state === "approval-requested" && <div className="approval-actions"><p>承認するとデモDBへ登録します。外部仕入先へ送信しません。</p><button data-testid="approve" disabled={busy} onClick={() => onApproval?.({ id: record.approval.id, approved: true })}>承認して登録</button><button className="secondary" data-testid="deny" disabled={busy} onClick={() => onApproval?.({ id: record.approval.id, approved: false })}>拒否する</button></div>}
      {record.state === "output-denied" && <p>登録しませんでした。</p>}
      {record.output?.order && <p data-testid="order-result">登録番号 #{record.output.order.id} · {money(record.output.order.estimated_cost_yen)}</p>}
      {rows.map((row, index) => (
        <div className="tool-row" key={`${String(row.sku)}-${index}`}>
          <strong>{String(row.name ?? row.sku ?? "結果")}</strong>
          <span>{String(row.sku ?? "")}</span>
          {name === "search_inventory" && <b>利用可能 {String(row.available_stock)}点</b>}
          {name === "review_sales" && <b>30日販売 {String(row.units_sold)}点</b>}
          {name === "check_supplier_terms" && <b>{String(row.lead_time_days)}日・{money(row.unit_cost_yen)}</b>}
          {name === "calculate_replenishment" && <b>{String(row.recommended_order_quantity)}点・{money(row.estimated_cost_yen)}</b>}
        </div>
      ))}
      {record.state === "output-error" && <p className="inline-error">{String(record.errorText)}</p>}
      <details><summary>ツールのraw state</summary><pre>{JSON.stringify(part, null, 2)}</pre></details>
    </section>
  );
}

type PartProps = { part: UIMessagePart<any, any>; onApproval?: (decision: ApprovalDecision) => void; busy?: boolean };
export function PartView({ part, onApproval, busy }: PartProps) {
  if (part.type === "step-start") return null;
  if (part.type === "text") return <div className="answer" data-part-type="text">{part.text}</div>;
  if (part.type === "reasoning") return <details className="reasoning"><summary>推論サマリー</summary><p>{part.text}</p></details>;
  if (toolName(part)) return <ToolCard part={part} onApproval={onApproval} busy={busy} />;
  if (part.type === "data-run") {
    const run = (part as any).data as RunData;
    return <div className="run-chip" data-testid="run-meta">{run.adapter === "openai" ? "公式SDK" : "RubyLLM"} · {run.model} · {run.reasoning_effort}</div>;
  }
  return <details className="raw"><summary>{part.type}</summary><pre>{JSON.stringify(part, null, 2)}</pre></details>;
}

function ChatSession({ conversation, onNew, onChanged, onBusy, onSaved }: { conversation: Conversation; onNew: () => void; onChanged: () => void; onBusy: (busy: boolean) => void; onSaved: (id: string) => void }) {
  const adapter = conversation.adapter;
  const [input, setInput] = useState<string>("");
  const [debugError, setDebugError] = useState(false);
  const [runData, setRunData] = useState<RunData | null>(null);
  const savedId = useRef(conversation.draft ? null : conversation.id);
  const transport = useMemo(() => new DefaultChatTransport({
    api: `/chat/${adapter}`, headers: sessionHeaders,
    prepareSendMessagesRequest: async ({ messages, body, trigger, messageId }) => {
      if (!savedId.current) {
        const saved = await startConversation(adapter);
        savedId.current = saved.id;
        sessionStorage.setItem("stockroom-conversation", saved.id);
        onSaved(saved.id);
      }
      return { body: { ...body, id: savedId.current, messages, trigger, messageId } };
    },
  }), [adapter]);
  const { messages, status, error, sendMessage, regenerate, stop, clearError, addToolApprovalResponse } = useChat({
    id: conversation.id, transport, messages: conversation.messages,
    sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithApprovalResponses,
    onFinish: onChanged,
    onData: (part) => { if (part.type === "data-run") setRunData((part as any).data as RunData); },
  });
  const busy = status === "submitted" || status === "streaming";
  useEffect(() => { onBusy(busy); return () => onBusy(false); }, [busy, onBusy]);
  const awaitingApproval = messages.some((m) => m.parts.some((p: any) => p.state === "approval-requested" || p.state === "approval-responded"));

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    const text = input.trim();
    if (!text || busy) return;
    if (error) clearError();
    setInput("");
    void sendMessage({ text }, { body: { debug_error: debugError } });
    setDebugError(false);
  };


  return (
    <main className="chat-shell">
      <header className="topbar">
        <div><b>在庫補充アシスタント</b><span>デモデータ</span></div>
        <button className="ghost" data-testid="new-chat-mobile" disabled={busy} onClick={onNew}>新しい会話</button>
      </header>
      <section className="messages" data-testid="messages">
        {adapter === "no-llm-call" && <p className="demo-notice">API不要の固定イベントデモです。入力内容に関係なく、元のDemoModelのtext・reasoning・tool callを表示します。</p>}
        {runData && <div className="run-chip" data-testid="run-meta">{runData.adapter === "openai" ? "公式SDK" : "RubyLLM"} · {runData.model} · {runData.reasoning_effort}</div>}
        {messages.length === 0 && (
          <div className="welcome"><span>◫</span><h1>今日は何を補充しますか？</h1><p>在庫・販売実績・仕入条件をツールで調べ、発注候補を計算します。</p></div>
        )}
        {messages.map((message: UIMessage) => (
          <article className={`message ${message.role}`} key={message.id} data-testid={`message-${message.role}`}>
            <div className="avatar">{message.role === "user" ? "あなた" : "AI"}</div>
            <div className="bubble">{message.parts.map((part, index) => <PartView key={`${part.type}-${index}`} part={part} onApproval={(decision) => void addToolApprovalResponse(decision)} busy={busy} />)}</div>
          </article>
        ))}
        {error && <div className="error" role="alert"><b>応答を完了できませんでした</b><span>{error.message}</span><button onClick={() => void regenerate({ body: { regenerate: true } })}>もう一度試す</button></div>}
      </section>
      <footer className="composer-wrap">
        <div className="templates" aria-label="依頼テンプレート">{templates.map((item) => <button data-testid={`template-${item.label}`} key={item.label} disabled={busy} onClick={() => setInput(item.text)}>{item.label}</button>)}</div>
        <form className="composer" onSubmit={submit}>
          <textarea data-testid="composer" value={input} onChange={(e) => setInput(e.target.value)} aria-label="AIへの依頼" disabled={awaitingApproval} placeholder="在庫について依頼する" rows={3} />
          <div className="composer-actions">
            <details><summary>検証設定</summary><label><input type="checkbox" checked={debugError} onChange={(e) => setDebugError(e.target.checked)} /> 次の送信でエラーを注入</label></details>
            {busy ? <button type="button" className="stop" data-testid="stop" onClick={() => void stop()}>停止</button> : <button type="submit" className="send" data-testid="send" disabled={!input.trim() || awaitingApproval}>送信</button>}
          </div>
        </form>
        {messages.some((message) => message.role === "assistant") && !busy && !awaitingApproval && <button className="regenerate" data-testid="regenerate" onClick={() => void regenerate({ body: { regenerate: true } })}>↻ この回答を再生成</button>}
        <small className="footnote">Enterは改行です。送信ボタンで送信します。外部仕入先への発注送信は行いません。</small>
      </footer>
    </main>
  );
}

function DashboardView({ data, onReset, onChat }: { data: Dashboard | null; onReset: () => void; onChat: () => void }) {
  return <main className="dashboard" data-testid="dashboard">
    <header className="page-heading"><div><p className="eyebrow">STOCKROOM / デモデータ</p><h1>在庫ダッシュボード</h1><p>在庫・販売・仕入条件を確認し、補充を管理します。</p></div><button onClick={onChat}>AIに相談する</button></header>
    {!data ? <p>読み込み中…</p> : <>
      <div className="stats"><section><span>商品数</span><strong>{data.inventory.length}</strong></section><section><span>発注点を下回る商品</span><strong>{data.inventory.filter((i) => i.available_stock < i.reorder_point).length}</strong></section><section><span>登録した補充発注</span><strong data-testid="order-count">{data.orders.length}</strong></section></div>
      <section className="data-card"><h2>在庫と仕入条件</h2><div className="table-scroll"><table><thead><tr><th>商品 / SKU</th><th>利用可能在庫</th><th>30日販売</th><th>在庫日数</th><th>仕入先 / 納期</th><th>仕入単価</th></tr></thead><tbody>{data.inventory.map((item) => { const sale = data.sales.find((s) => s.sku === item.sku); const supplier = data.suppliers.find((s) => s.sku === item.sku); return <tr key={item.sku}><td><strong>{item.name}</strong><small>{item.sku}</small></td><td><span className={item.available_stock < item.reorder_point ? "warning" : ""}>{item.available_stock}点</span></td><td>{sale?.units_sold}点</td><td>{sale?.days_of_cover ?? "—"}日</td><td>{supplier?.supplier_name}<small>{supplier?.lead_time_days}日</small></td><td>{money(supplier?.unit_cost_yen)}</td></tr>; })}</tbody></table></div></section>
      <section className="data-card"><h2>補充発注 <span>デモDBへの登録のみ</span></h2>{data.orders.length === 0 ? <p className="empty-state">登録済みの補充発注はありません。AIに相談し、提案を承認するとここへ反映されます。</p> : <div className="table-scroll"><table data-testid="orders"><thead><tr><th>登録番号</th><th>SKU</th><th>数量</th><th>概算費用</th><th>状態</th></tr></thead><tbody>{data.orders.map((order) => <tr key={order.id}><td>#{order.id}</td><td>{order.sku}</td><td>{order.quantity}点</td><td>{money(order.estimated_cost_yen)}</td><td><span className="success">登録済み・未送信</span></td></tr>)}</tbody></table></div>}</section>
      <p className="reset-note">これは共有のデモデータです。<button className="text-button" data-testid="reset-demo" onClick={onReset}>デモデータをリセット</button></p>
    </>}
  </main>;
}

export function App() {
  const [adapter, setAdapter] = useState<Adapter>((sessionStorage.getItem("stockroom-adapter") as Adapter) || "openai");
  const [conversation, setConversation] = useState<Conversation | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(false);
  const selection = useRef(0);
  const [data, setData] = useState<Dashboard | null>(null);
  const [page, setPage] = useState<"dashboard" | "chat" | "history">("dashboard");
  const [error, setError] = useState("");
  const [resetConfirm, setResetConfirm] = useState(false);
  const refresh = () => {
    void getDashboard().then(setData).catch((e) => setError(e.message));
    void listConversations().then(setConversations).catch((e) => setError(e.message));
  };
  const select = (value: Conversation) => {
    setConversation(value); setSelectedId(value.id); setAdapter(value.adapter);
    sessionStorage.setItem("stockroom-conversation", value.id);
    sessionStorage.setItem("stockroom-adapter", value.adapter);
    setPage("chat");
  };
  const loadChat = async (id: string) => {
    const request = ++selection.current;
    setLoading(true); setError("");
    try { const value = await getConversation(id); if (request === selection.current) select(value); }
    catch (e) { if (request === selection.current) setError((e as Error).message); }
    finally { if (request === selection.current) setLoading(false); }
  };
  useEffect(() => {
    refresh();
    const id = sessionStorage.getItem("stockroom-conversation");
    if (id) void loadChat(id);
  }, []);
  const newChat = (next = adapter) => {
    ++selection.current;
    setLoading(false); setError(""); setSelectedId(null); setAdapter(next);
    setConversation({ id: crypto.randomUUID(), adapter: next, title: "新しい会話", updated_at: "", messages: [], draft: true });
    sessionStorage.removeItem("stockroom-conversation");
    sessionStorage.setItem("stockroom-adapter", next);
    setPage("chat");
  };
  const openChat = () => { if (conversation) setPage("chat"); else void newChat(); };
  return <div className="app-frame">
    <aside className="sidebar"><div className="brand"><span>◫</span><b>Stockroom AI</b></div><nav><button className={page === "dashboard" ? "active" : ""} data-testid="nav-dashboard" onClick={() => setPage("dashboard")}>在庫ダッシュボード</button><button className={page === "chat" ? "active" : ""} data-testid="nav-chat" disabled={loading} onClick={openChat}>AIアシスタント</button></nav><button className="new-chat" data-testid="new-chat" disabled={busy || loading} onClick={() => void newChat()}>＋ 新しい会話</button><nav className="conversation-list" aria-label="過去の会話" data-testid="conversation-list"><small>過去の会話</small>{conversations.slice(0, 10).map((item) => <button key={item.id} data-testid={`conversation-${item.id}`} aria-current={selectedId === item.id ? "true" : undefined} className={selectedId === item.id ? "active" : ""} disabled={busy || loading} onClick={() => void loadChat(item.id)}>{item.title}</button>)}</nav><button className="new-chat" data-testid="all-conversations" onClick={() => { refresh(); setPage("history"); }}>会話一覧を見る</button><nav><small>モデル接続</small>{([ ["openai", "公式 OpenAI SDK"], ["ruby_llm", "RubyLLM"], ["no-llm-call", "API不要デモ"] ] as const).map(([value, label]) => <button className={adapter === value ? "active" : ""} disabled={busy || loading} data-testid={`adapter-${value}`} key={value} onClick={() => void newChat(value)}>{label}</button>)}</nav><div className="sidebar-note"><b>デモデータ環境</b><span>gpt-5.6-luna / medium</span></div></aside>
    <div className="content">{error && <p className="error" role="alert">{error}</p>}{page === "dashboard" ? <DashboardView data={data} onReset={() => setResetConfirm(true)} onChat={openChat} /> : null}{page === "history" && <main className="dashboard" data-testid="history-page"><header className="page-heading"><div><h1>会話一覧</h1><p>過去の会話を選んで続けられます。</p></div></header><section className="data-card history-list">{conversations.length === 0 ? <p className="empty-state">会話はまだありません。</p> : conversations.map((item) => <button key={item.id} data-testid={`history-${item.id}`} disabled={busy || loading} onClick={() => void loadChat(item.id)}><span>{item.title}</span><small>{new Date(item.updated_at).toLocaleDateString("ja-JP")}</small></button>)}</section></main>}<div hidden={page !== "chat"}>{loading ? <p role="status">会話を読み込み中…</p> : conversation && <ChatSession key={conversation.id} conversation={conversation} onNew={() => void newChat()} onChanged={refresh} onBusy={setBusy} onSaved={setSelectedId} />}</div></div>
    {resetConfirm && <div className="modal-backdrop"><section className="confirm-card" role="dialog" aria-modal="true" aria-labelledby="reset-title"><h2 id="reset-title">デモデータをリセットしますか？</h2><p>在庫・販売・仕入条件を初期状態へ戻し、登録した補充発注を削除します。保留中の承認は使えなくなります。</p><button data-testid="confirm-reset" onClick={() => { void resetDemo().then((value) => { setData(value); setConversation(null); sessionStorage.removeItem("stockroom-conversation"); setResetConfirm(false); setPage("dashboard"); }).catch((e) => setError(e.message)); }}>リセットする</button><button className="secondary" onClick={() => setResetConfirm(false)}>キャンセル</button></section></div>}
  </div>;
}
