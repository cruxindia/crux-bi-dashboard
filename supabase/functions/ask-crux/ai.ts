// Provider-independent AI adapter. The API key is read from the server-side secret GEMINI_API_KEY only;
// nothing in this module logs keys, prompts or responses.
export type GenReq = { system?: string; prompt: string; maxTokens?: number; temperature?: number };
export type GenRes = {
  ok: boolean; text: string; model: string; status: number; retries: number; ms: number;
  promptTokens?: number; outputTokens?: number; finish?: string; error?: string;
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
}

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
