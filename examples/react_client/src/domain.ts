import type { UIMessage, UIMessagePart } from "ai";

export type Adapter = "openai" | "ruby_llm" | "no-llm-call";

// Public SaaS operations. The session token binds conversations to this browser
// session. Client history/tool arguments are never authority for a business write.
export type OrderInput = { sku: string; quantity: number };
export type Order = OrderInput & { id: number; estimated_cost_yen: number; supplier_name: string; status: "registered" };
export type Dashboard = {
  demo_data: true; revision: string;
  inventory: Array<{ sku: string; name: string; available_stock: number; reorder_point: number }>;
  sales: Array<{ sku: string; units_sold: number; days_of_cover: number | null }>;
  suppliers: Array<{ sku: string; supplier_name: string; lead_time_days: number; unit_cost_yen: number }>;
  orders: Order[];
};
export type ConversationSummary = { id: string; adapter: Adapter; title: string; updated_at: string };
export type Conversation = ConversationSummary & { messages: UIMessage[]; draft?: boolean };
export type ApprovalDecision = { id: string; approved: boolean };

export function sessionToken(): string {
  let token = sessionStorage.getItem("stockroom-session");
  if (!token) { token = crypto.randomUUID(); sessionStorage.setItem("stockroom-session", token); }
  return token;
}
export const sessionHeaders = () => ({ "X-Demo-Session": sessionToken() });
async function request<T>(path: string, method = "GET", body?: unknown): Promise<T> {
  const response = await fetch(path, { method, headers: { ...sessionHeaders(), "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  if (!response.ok) throw new Error((await response.json()).error ?? "操作に失敗しました");
  return response.json() as Promise<T>;
}
export const getDashboard = () => request<Dashboard>("/demo/dashboard");
// Explicit confirmation resets only the example's demo data; all old approvals
// become stale, including if reset restores identical rows.
export const resetDemo = () => request<Dashboard>("/demo/reset", "POST", { confirmed: true });
// Lists non-empty conversations owned by this browser session, newest first.
// A local draft is persisted only when its first message is submitted.
export const listConversations = () => request<ConversationSummary[]>("/demo/conversations");
export const getConversation = (id: string) => request<Conversation>(`/demo/conversations/${id}`);
export const startConversation = (adapter: Adapter) => request<Conversation>("/demo/conversations", "POST", { adapter });
// Chat submits only a new user's text, or AI SDK approval-responded parts.
// Backend validates session, conversation, tool call, exact input, and revision.
// Replayed decisions return the saved outcome and never execute a second write.

export type RunData = {
  run_id: string;
  adapter: Adapter;
  model: "gpt-5.6-luna";
  reasoning_effort: "medium";
  seed_version: string;
};

export type ToolOutput = {
  items?: Array<Record<string, unknown>>;
  proposals?: Array<Record<string, unknown>>;
  demo_data?: boolean;
};

export const templates = [
  { label: "欠品リスク", text: "全商品の在庫と直近30日の販売実績を調べ、欠品リスクが高い商品を補充提案してください。目標在庫日数は30日です。" },
  { label: "食品を確認", text: "食品カテゴリの在庫、販売ペース、仕入条件を確認し、急ぐべき補充を提案してください。" },
  { label: "予算を確認", text: "全商品の補充候補を調べ、概算仕入額と納期を含む優先順位を示してください。" },
  { label: "承認付き登録", text: "先ほどの食品のSKUを60点で補充発注登録してください。" },
] as const;

export function toolName(part: UIMessagePart<any, any>) {
  if (part.type === "dynamic-tool") return String((part as any).toolName);
  return part.type.startsWith("tool-") ? part.type.slice(5) : null;
}

export function asToolOutput(value: unknown): ToolOutput | null {
  if (value && typeof value === "object") return value as ToolOutput;
  if (typeof value !== "string") return null;
  try { return JSON.parse(value) as ToolOutput; } catch { return null; }
}
