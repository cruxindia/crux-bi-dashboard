// Provider-independent AI adapter. The API key is read from the server-side secret GEMINI_API_KEY only;
// nothing in this module logs keys, prompts or responses.
export type GenReq = { system?: string; prompt: string; maxTokens?: number; temperature?: number };
export type GenRes = {
  ok: boolean; text: string; model: string; status: number; retries: number; ms: number;
  promptTokens?: number; outputTokens?: number; finish?: string; error?: string; via?: string;
};
export type EmbRes = { ok: boolean; vectors: number[][]; model: string; status: number; retries: number; ms: number; error?: string };
export type ModelInfo = {
  model: string; display_name?: string; version?: string; methods: string[];
  input_token_limit?: number; output_token_limit?: number;
};
export interface AIProvider {
  readonly name: string;
  configured(): boolean;
  listModels(): Promise<ModelInfo[]>;
  generate(model: string, req: GenReq): Promise<GenRes>;
  embed(model: string, texts: string[], task: string, dim: number): Promise<EmbRes>;
  chat(model: string, req: ChatReq): Promise<ChatRes>;
}
// wave 105: multi-turn chat with function calling (Ask Crux agent). Model turns are kept exactly as returned (thought signatures included).
export type Part = Record<string, any>;
export type Content = { role: 'user' | 'model'; parts: Part[] };
export type ToolDecl = { name: string; description: string; parameters: Record<string, unknown> };
export type ChatReq = { system?: string; contents: Content[]; tools?: ToolDecl[]; noTools?: boolean; maxTokens?: number; temperature?: number; thinkingBudget?: number };
export type ChatRes = {
  ok: boolean; text: string; calls: { name: string; args: Record<string, unknown>; id?: string }[]; content?: Content;
  model: string; status: number; retries: number; ms: number; promptTokens?: number; outputTokens?: number; finish?: string; error?: string; via?: string;
};

const BASE = 'https://generativelanguage.googleapis.com/v1beta';
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Honour the provider's RetryInfo (e.g. "12s") when present; otherwise capped exponential backoff.
function retryDelay(j: any, attempt: number): number {
  const d = (j?.error?.details ?? []).find((x: any) => String(x?.['@type'] ?? '').includes('RetryInfo'))?.retryDelay;
  const s = d ? parseFloat(String(d)) : NaN;
  return Number.isFinite(s) ? s * 1000 : Math.min(8000, 800 * 2 ** attempt);
}

export function normalise(v: number[]): number[] {
  const n = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  return n > 0 ? v.map((x) => x / n) : v;
}

type CallRes = { ok: boolean; status: number; j: any; retries: number; ms: number; error?: string };

export class GeminiProvider implements AIProvider {
  readonly name = 'gemini';
  constructor(private key: string, private timeoutMs = 20000, private maxRetries = 2) {}
  configured() { return this.key.length > 0; }

  private async call(method: 'GET' | 'POST', path: string, body?: unknown): Promise<CallRes> {
    const t0 = Date.now();
    let retries = 0, status = 0, last = '';
    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      try {
        const r = await fetch(`${BASE}/${path}`, {
          method,
          headers: { 'Content-Type': 'application/json', 'x-goog-api-key': this.key },
          body: body === undefined ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        status = r.status;
        const txt = await r.text();
        let j: any = null;
        try { j = JSON.parse(txt); } catch { j = null; }
        if (r.ok && j) return { ok: true, status, j, retries, ms: Date.now() - t0 };
        last = String(j?.error?.status ?? '') + (j?.error?.message ? ': ' + String(j.error.message).slice(0, 200) : (j ? '' : ` HTTP ${status} (non-JSON response)`));
        const retryable = status === 429 || status >= 500;
        if (!retryable || attempt === this.maxRetries) return { ok: false, status, j, retries, ms: Date.now() - t0, error: last || `HTTP ${status}` };
        const wait = retryDelay(j, attempt);
        if (wait > 10000) return { ok: false, status, j, retries, ms: Date.now() - t0, error: (last || `HTTP ${status}`) + ' (provider asked to wait longer than 10 s)' };
        retries++;
        await sleep(wait);
      } catch (e) {
        last = (e as Error)?.name === 'TimeoutError' ? `timeout after ${this.timeoutMs} ms` : 'network error';
        if (attempt === this.maxRetries) return { ok: false, status: 0, j: null, retries, ms: Date.now() - t0, error: last };
        retries++;
        await sleep(Math.min(4000, 800 * 2 ** attempt));
      }
    }
    return { ok: false, status, j: null, retries, ms: Date.now() - t0, error: last };
  }

  async listModels(): Promise<ModelInfo[]> {
    const out: ModelInfo[] = [];
    let page = '';
    for (let i = 0; i < 5; i++) {
      const r = await this.call('GET', `models?pageSize=1000${page ? `&pageToken=${encodeURIComponent(page)}` : ''}`);
      if (!r.ok) throw new Error(`models.list failed (${r.status}): ${r.error}`);
      for (const m of r.j?.models ?? []) {
        out.push({
          model: String(m.name ?? '').replace(/^models\//, ''), display_name: m.displayName, version: m.version,
          methods: m.supportedGenerationMethods ?? [], input_token_limit: m.inputTokenLimit, output_token_limit: m.outputTokenLimit,
        });
      }
      page = r.j?.nextPageToken ?? '';
      if (!page) break;
    }
    return out;
  }

  async generate(model: string, q: GenReq): Promise<GenRes> {
    const body: any = {
      contents: [{ role: 'user', parts: [{ text: q.prompt }] }],
      generationConfig: { temperature: q.temperature ?? 0.1, maxOutputTokens: q.maxTokens ?? 1024,
        // short rewording task: no hidden "thinking" tokens (they count against the output limit and truncate answers)
        ...(/^gemini-2\.5-flash/.test(model) ? { thinkingConfig: { thinkingBudget: 0 } } : {}) },
    };
    if (q.system) body.systemInstruction = { parts: [{ text: q.system }] };
    const r = await this.call('POST', `models/${encodeURIComponent(model)}:generateContent`, body);
    const base = { model, status: r.status, retries: r.retries, ms: r.ms };
    if (!r.ok) return { ...base, ok: false, text: '', error: r.error };
    if (r.j?.promptFeedback?.blockReason) return { ...base, ok: false, text: '', error: 'blocked: ' + r.j.promptFeedback.blockReason };
    const c = r.j?.candidates?.[0];
    if (!c) return { ...base, ok: false, text: '', error: 'no candidates in response' };
    const text = (c.content?.parts ?? []).map((p: any) => (typeof p?.text === 'string' && !p.thought ? p.text : '')).join('').trim();
    const u = r.j?.usageMetadata ?? {};
    const usage = { promptTokens: u.promptTokenCount, outputTokens: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0) };
    if (!text) return { ...base, ...usage, ok: false, text: '', finish: c.finishReason, error: `empty content (finish reason ${c.finishReason ?? 'unknown'})` };
    if (c.finishReason && c.finishReason !== 'STOP') return { ...base, ...usage, ok: false, text, finish: c.finishReason, error: `incomplete answer (finish reason ${c.finishReason})` };
    return { ...base, ...usage, ok: true, text, finish: c.finishReason };
  }

  async chat(model: string, q: ChatReq): Promise<ChatRes> {
    const gc: any = { temperature: q.temperature ?? 0.2, maxOutputTokens: q.maxTokens ?? 4096 };
    if (/^gemini-2\.5-flash/.test(model)) gc.thinkingConfig = { thinkingBudget: q.thinkingBudget ?? 1024 };
    const body: any = { contents: q.contents, generationConfig: gc };
    if (q.system) body.systemInstruction = { parts: [{ text: q.system }] };
    if (q.tools?.length) {
      body.tools = [{ functionDeclarations: q.tools }];
      body.toolConfig = { functionCallingConfig: { mode: q.noTools ? 'NONE' : 'AUTO' } };
    }
    const r = await this.call('POST', `models/${encodeURIComponent(model)}:generateContent`, body);
    const base = { model, status: r.status, retries: r.retries, ms: r.ms, calls: [] as ChatRes['calls'] };
    if (!r.ok) return { ...base, ok: false, text: '', error: r.error };
    if (r.j?.promptFeedback?.blockReason) return { ...base, ok: false, text: '', error: 'blocked: ' + r.j.promptFeedback.blockReason };
    const c = r.j?.candidates?.[0];
    if (!c) return { ...base, ok: false, text: '', error: 'no candidates in response' };
    const parts: Part[] = c.content?.parts ?? [];
    const calls = parts.filter((p) => p?.functionCall?.name).map((p) => ({ name: String(p.functionCall.name), args: (p.functionCall.args ?? {}) as Record<string, unknown>, id: p.functionCall.id }));
    const text = parts.map((p) => (typeof p?.text === 'string' && !p.thought ? p.text : '')).join('').trim();
    const u = r.j?.usageMetadata ?? {};
    const usage = { promptTokens: u.promptTokenCount, outputTokens: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0) };
    if (!calls.length && !text) return { ...base, ...usage, ok: false, text: '', finish: c.finishReason, error: `empty content (finish reason ${c.finishReason ?? 'unknown'})` };
    if (!calls.length && c.finishReason && c.finishReason !== 'STOP') return { ...base, ...usage, ok: false, text, finish: c.finishReason, error: `incomplete answer (finish reason ${c.finishReason})` };
    return { ...base, ...usage, ok: true, text, calls, content: { role: 'model', parts }, finish: c.finishReason };
  }

  async embed(model: string, texts: string[], task: string, dim: number): Promise<EmbRes> {
    const body = { requests: texts.map((t) => ({ model: `models/${model}`, content: { parts: [{ text: t }] }, taskType: task, outputDimensionality: dim })) };
    const r = await this.call('POST', `models/${encodeURIComponent(model)}:batchEmbedContents`, body);
    const base = { model, status: r.status, retries: r.retries, ms: r.ms };
    if (!r.ok) return { ...base, ok: false, vectors: [], error: r.error };
    const vs: number[][] = (r.j?.embeddings ?? []).map((e: any) => normalise((e?.values ?? []).map(Number)));
    if (vs.length !== texts.length || vs.some((v) => v.length !== dim || v.some((x) => !Number.isFinite(x)))) {
      return { ...base, ok: false, vectors: [], error: `unexpected embedding shape (${vs.length} x ${vs[0]?.length ?? 0})` };
    }
    return { ...base, ok: true, vectors: vs };
  }
}

export function provider(timeoutMs = 20000, maxRetries = 2): AIProvider {
  return new GeminiProvider(Deno.env.get('GEMINI_API_KEY') ?? '', timeoutMs, maxRetries);
}

// wave 105f: OpenRouter as the backup AI (owner 9-Nov: keep Gemini, OpenRouter as backup, no paid use).
// OpenAI-compatible chat completions with tool calling; the agent's Gemini-style turns are translated both ways.
// Only free models are allowed unless OPENROUTER_PAID_ALLOWED = on, and every request asks for providers that do not train on the data.
const OR_URL = 'https://openrouter.ai/api/v1/chat/completions';
export const orFree = (m: string) => m === 'openrouter/free' || /:free$/.test(m);
function toOpenAI(q: ChatReq): any[] {
  const msgs: any[] = [];
  if (q.system) msgs.push({ role: 'system', content: q.system });
  let pending: string[] = [];
  q.contents.forEach((c, ci) => {
    if (c.role === 'model') {
      const text = c.parts.filter((p) => typeof p?.text === 'string' && !p.thought).map((p) => p.text).join('');
      const calls = c.parts.filter((p) => p?.functionCall?.name).map((p, i) => ({ id: String(p.functionCall.id ?? `call_${ci}_${i}`), type: 'function',
        function: { name: String(p.functionCall.name), arguments: JSON.stringify(p.functionCall.args ?? {}) } }));
      pending = calls.map((x) => x.id);
      msgs.push(calls.length ? { role: 'assistant', content: text || null, tool_calls: calls } : { role: 'assistant', content: text });
    } else {
      const frs = c.parts.filter((p) => p?.functionResponse);
      frs.forEach((p, i) => msgs.push({ role: 'tool', tool_call_id: String(p.functionResponse.id ?? pending[i] ?? `call_${ci}_${i}`), content: JSON.stringify(p.functionResponse.response ?? {}) }));
      const text = c.parts.filter((p) => typeof p?.text === 'string').map((p) => p.text).join('\n');
      if (text) msgs.push({ role: 'user', content: text });
    }
  });
  return msgs;
}
export class OpenRouterProvider implements AIProvider {
  readonly name = 'openrouter';
  constructor(private key: string, private timeoutMs = 25000, private paidAllowed = false) {}
  configured() { return this.key.length > 0; }
  async listModels(): Promise<ModelInfo[]> { return []; }
  async embed(model: string): Promise<EmbRes> { return { ok: false, vectors: [], model, status: 0, retries: 0, ms: 0, error: 'embeddings not used on OpenRouter' }; }
  async generate(model: string, q: GenReq): Promise<GenRes> {
    const r = await this.chat(model, { system: q.system, contents: [{ role: 'user', parts: [{ text: q.prompt }] }], maxTokens: q.maxTokens, temperature: q.temperature });
    return { ok: r.ok, text: r.text, model, status: r.status, retries: r.retries, ms: r.ms, promptTokens: r.promptTokens, outputTokens: r.outputTokens, finish: r.finish, error: r.error };
  }
  async chat(model: string, q: ChatReq): Promise<ChatRes> {
    const t0 = Date.now();
    const base = { model, status: 0, retries: 0, ms: 0, calls: [] as ChatRes['calls'] };
    if (!this.configured()) return { ...base, ok: false, text: '', error: 'OPENROUTER_API_KEY is not set' };
    if (!this.paidAllowed && !orFree(model)) return { ...base, status: 403, ok: false, text: '', error: `paid model ${model} refused (no paid use)` };
    const body: any = { model, messages: toOpenAI(q), max_tokens: q.maxTokens ?? 4096, temperature: q.temperature ?? 0.2, provider: { data_collection: 'deny' } };
    if (q.tools?.length) { body.tools = q.tools.map((t) => ({ type: 'function', function: t })); if (q.noTools) body.tool_choice = 'none'; }
    let status = 0, j: any = null;
    try {
      const r = await fetch(OR_URL, { method: 'POST', signal: AbortSignal.timeout(this.timeoutMs),
        headers: { Authorization: `Bearer ${this.key}`, 'Content-Type': 'application/json', 'HTTP-Referer': 'https://cruxindia.github.io/crux-bi-dashboard/', 'X-OpenRouter-Title': 'Crux BI' },
        body: JSON.stringify(body) });
      status = r.status;
      const txt = await r.text();
      try { j = JSON.parse(txt); } catch { j = null; }
      if (!r.ok || !j || j.error) {
        const st = j?.error?.code && Number.isFinite(+j.error.code) ? +j.error.code : status;
        return { ...base, status: st || status, ms: Date.now() - t0, ok: false, text: '', error: String(j?.error?.message ?? `HTTP ${status}`).slice(0, 200) };
      }
    } catch (e) {
      return { ...base, ms: Date.now() - t0, ok: false, text: '', error: (e as Error)?.name === 'TimeoutError' ? `timeout after ${this.timeoutMs} ms` : 'network error' };
    }
    const c = j.choices?.[0], m = c?.message ?? {};
    const tc: any[] = Array.isArray(m.tool_calls) ? m.tool_calls : [];
    const calls = tc.map((x, i) => { let args: Record<string, unknown> = {}; try { args = JSON.parse(x.function?.arguments || '{}'); } catch { args = {}; }
      return { name: String(x.function?.name ?? ''), args, id: String(x.id ?? `or_${Date.now()}_${i}`) }; }).filter((x) => x.name);
    const text = typeof m.content === 'string' ? m.content.replace(/<think>[\s\S]*?<\/think>/g, '').trim() : '';
    const usage = { promptTokens: j.usage?.prompt_tokens, outputTokens: j.usage?.completion_tokens };
    const done = { ...base, ...usage, status, ms: Date.now() - t0, model: `${model}${j.model && j.model !== model ? ' → ' + j.model : ''}` };
    if (!calls.length && !text) return { ...done, ok: false, text: '', finish: c?.finish_reason, error: `empty content (finish reason ${c?.finish_reason ?? 'unknown'})` };
    const parts: Part[] = [...(text ? [{ text }] : []), ...calls.map((x) => ({ functionCall: { name: x.name, args: x.args, id: x.id } }))];
    return { ...done, ok: true, text, calls, content: { role: 'model', parts }, finish: c?.finish_reason };
  }
}
// routes "or:<model>" to OpenRouter and everything else to Gemini
export class MultiProvider implements AIProvider {
  readonly name = 'multi';
  constructor(private g: AIProvider, private o: AIProvider) {}
  configured() { return this.g.configured(); }
  listModels() { return this.g.listModels(); }
  private pick(m: string): [AIProvider, string] { return m.startsWith('or:') ? [this.o, m.slice(3)] : [this.g, m]; }
  async generate(m: string, q: GenReq) { const [p, x] = this.pick(m); const r = await p.generate(x, q); return { ...r, model: p === this.o ? 'or:' + r.model : r.model }; }
  embed(m: string, t: string[], k: string, d: number) { return this.g.embed(m, t, k, d); }
  async chat(m: string, q: ChatReq) { const [p, x] = this.pick(m); const r = await p.chat(x, q); return { ...r, model: p === this.o ? 'or:' + r.model : r.model }; }
}
// wave 109b: each agent has its own key (a separate project, owner 13-Nov-2026). The main key is used only when the agent's key itself is refused
// (invalid, revoked or the API not enabled) — never to get round a quota: a 429 stays a 429 and the agent moves on to its fallback model or the backup engine.
const keyRefused = (r: { ok: boolean; status: number; error?: string }) =>
  !r.ok && (r.status === 401 || r.status === 403 || (r.status === 400 && /API[_ ]?KEY|api key/i.test(r.error ?? '')));
export class KeyFailover implements AIProvider {
  readonly name = 'gemini';
  constructor(private own: AIProvider, private main: AIProvider) {}
  configured() { return this.own.configured() || this.main.configured(); }
  listModels() { return this.own.configured() ? this.own.listModels() : this.main.listModels(); }
  async generate(m: string, q: GenReq) { const r = await this.own.generate(m, q); return keyRefused(r) && this.main.configured() ? { ...(await this.main.generate(m, q)), via: 'main' } : r; }
  async chat(m: string, q: ChatReq) { const r = await this.own.chat(m, q); return keyRefused(r) && this.main.configured() ? { ...(await this.main.chat(m, q)), via: 'main' } : r; }
  embed(m: string, t: string[], k: string, d: number) { return this.main.embed(m, t, k, d); }
}
// wave 106a: the backup key comes from the Edge Function secret OPENROUTER_API_KEY or, when that is not set, from Vault (passed in by index.ts)
// retries: scheduled jobs pass 1 so a short "busy / resource exhausted" spell (seen 13-Nov 23:15 IST) is waited out once on the same key and model
export function multiProvider(timeoutMs = 25000, paidAllowed = false, backupKey?: string, agentKey?: string, retries = 0): AIProvider {
  const main = new GeminiProvider(Deno.env.get('GEMINI_API_KEY') ?? '', timeoutMs, retries);
  const g = agentKey ? new KeyFailover(new GeminiProvider(agentKey, timeoutMs, retries), main) : main;
  return new MultiProvider(g, new OpenRouterProvider(Deno.env.get('OPENROUTER_API_KEY') || backupKey || '', timeoutMs, paidAllowed));
}
// wave 109b: key check without spending tokens (lists one model); the key is never returned or logged
export async function checkKey(key: string): Promise<{ ok: boolean; status: number; note: string }> {
  try {
    const r = await fetch(`${BASE}/models?pageSize=1`, { headers: { 'x-goog-api-key': key }, signal: AbortSignal.timeout(10000) });
    const j: any = await r.json().catch(() => null);
    return { ok: r.ok, status: r.status, note: r.ok ? 'key accepted' : String(j?.error?.status ?? '') + (j?.error?.message ? ': ' + String(j.error.message).slice(0, 160) : '') };
  } catch (e) { return { ok: false, status: 0, note: (e as Error)?.name === 'TimeoutError' ? 'timeout' : 'network error' }; }
}

// Model choice: a stable "gemini-X.Y-flash" model (highest version) is preferred over moving aliases such as
// gemini-flash-latest; the configured candidate is tried after the stable ones.
const ver = (m: string) => { const x = m.match(/-(\d+(?:\.\d+)?)-/); return x ? parseFloat(x[1]) : 0; };
export function generationCandidates(models: ModelInfo[], configured: string): string[] {
  const gen = models.filter((m) => m.methods.includes('generateContent'));
  const stable = gen.filter((m) => /^gemini-\d+(\.\d+)?-flash$/.test(m.model)).sort((a, b) => ver(b.model) - ver(a.model)).map((m) => m.model);
  const out = [...stable];
  for (const c of [configured, 'gemini-flash-latest']) if (c && gen.some((m) => m.model === c) && !out.includes(c)) out.push(c);
  return out;
}
// lighter stable Flash-Lite models, used only as a fallback when the main model is overloaded
export function fallbackCandidates(models: ModelInfo[]): string[] {
  return models.filter((m) => m.methods.includes('generateContent') && /^gemini-\d+(\.\d+)?-flash-lite$/.test(m.model))
    .sort((a, b) => ver(b.model) - ver(a.model)).map((m) => m.model);
}
export function embeddingCandidates(models: ModelInfo[]): string[] {
  const emb = models.filter((m) => m.methods.includes('embedContent') || m.methods.includes('batchEmbedContents'));
  const stable = emb.filter((m) => /^gemini-embedding-\d+$/.test(m.model)).sort((a, b) => b.model.localeCompare(a.model)).map((m) => m.model);
  const rest = emb.filter((m) => !stable.includes(m.model) && /^gemini-embedding/.test(m.model) && !/exp/.test(m.model)).map((m) => m.model);
  return [...stable, ...rest];
}
