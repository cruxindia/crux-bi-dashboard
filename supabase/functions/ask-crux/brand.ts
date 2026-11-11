// wave 105h (owner 9-Nov-2026 19:25): "i don't want to give away which AI is being used ... Only reference of AI to be used is 'Ask Crux'".
// Nothing the dashboard shows names an AI model, vendor or provider. Responses carry no model names; text written by the AI (answers,
// report bodies, error notes) passes through noVendor() before it is stored or shown. Market-news headlines are quoted from the feeds
// and are left as published (a bank's own AI news is news, not a statement about Ask Crux).
// The same patterns are used by the page (web/index.src.html, noVendor) for text stored before this wave.
const VENDOR: RegExp[] = [
  /\b(?:google\s+)?gemini(?:[\s-]*\d+(?:\.\d+)*)?(?:[\s-]+(?:pro|flash|lite|ultra|nano|embedding|exp|preview|thinking|latest|\d+(?:\.\d+)*)\b)*/gi,
  /\bor:[\w./:~-]+/gi,
  /\bopen\s?router(?:\/[\w.:-]+)?/gi,
  /~?\bopen\s?ai\b(?:\/[\w.:-]+)?/gi,
  /\b(?:chat\s?)?gpt(?:-[\w.]+)*(?:\s?\d[\w.]*)?\b/gi,
  /\banthropic\b/gi,
  /\bclaude(?:[\s-]+(?:opus|sonnet|haiku|code|fable|mythos))?(?:[\s-]*\d+(?:\.\d+)*)?\b/gi,
  /\b(?:meta[\s-]+)?llama[\w.-]*(?::free)?/gi,
  /\b(?:deepseek|qwen|mistral|mixtral|gemma)[\w.-]*(?::free)?/gi,
  /\b(?:google\s+)?(?:ai\s+studio|generative\s?language\s?api)\b/gi,
];
export function noVendor(s: unknown): string {
  let t = String(s ?? '');
  for (const r of VENDOR) t = t.replace(r, 'Ask Crux');
  // "Ask Crux / Ask Crux", "Ask Crux, Ask Crux" → one name
  return t.replace(/Ask Crux(?:\s*[,/+&]\s*Ask Crux|\s+Ask Crux)+/g, 'Ask Crux').replace(/~Ask Crux/g, 'Ask Crux');
}
// JSON-safe: applies noVendor to every string inside a value (keys untouched)
export function noVendorDeep<T>(v: T): T {
  if (typeof v === 'string') return noVendor(v) as unknown as T;
  if (Array.isArray(v)) return v.map((x) => noVendorDeep(x)) as unknown as T;
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, noVendorDeep(x)])) as T;
  return v;
}
// which configured engine answered, without naming it: the first configured model is "main", any other is "backup"
export const engineOf = (model: string | null | undefined, main: string | null | undefined) => (!model ? null : model === main ? 'main' : 'backup');
