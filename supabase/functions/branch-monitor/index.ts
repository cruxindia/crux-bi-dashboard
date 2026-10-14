// branch-monitor — monthly client-branch monitoring (Supabase Cron -> this function).
// Banks: re-reads the RBI IFSC directory (machine-readable release of razorpay/ifsc, compiled from the RBI NEFT/RTGS lists),
// compares it with the branch master through public.bi_branch_job (adds, updates, "missing from source" review items, duplicates).
// Non-bank lenders: re-checks each recorded official branch page; a changed page opens a review item (no automatic parsing).
// Idempotent and resumable: work is recorded per client family in bi.job_run; repeated ticks continue or skip.
// Protected: requires a job token (scope job) or an admin key. No secrets are logged.
const URL_ = Deno.env.get('SUPABASE_URL')!;
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const UA = 'CruxBI-branch-monitor/1.0 (monthly check of public branch directories; contact: Crux India)';
const BUDGET_MS = 110_000; // stay inside the 150 s wall clock of the free plan
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });

async function rpc(fn: string, p: unknown) {
  const r = await fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: SR, Authorization: `Bearer ${SR}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p }), signal: AbortSignal.timeout(120000) });
  const t = await r.text(); if (!r.ok) throw new Error(`${fn}: ${t.slice(0, 300)}`); return JSON.parse(t);
}
const job = (p: Record<string, unknown>) => rpc('bi_branch_job', p);

async function fetchRetry(url: string, init: RequestInit = {}, tries = 3, timeout = 60000): Promise<Response> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, { ...init, headers: { 'User-Agent': UA, ...(init.headers ?? {}) }, signal: AbortSignal.timeout(timeout) });
      if (r.ok) return r;
      last = new Error(`HTTP ${r.status} for ${url}`);
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) { last = e; }
    await new Promise((res) => setTimeout(res, 1500 * (i + 1)));
  }
  throw last instanceof Error ? last : new Error(String(last));
}

// robots.txt check for a path (simple user-agent * rules)
async function robotsAllows(u: URL): Promise<boolean> {
  try {
    const r = await fetch(`${u.origin}/robots.txt`, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(10000) });
    if (!r.ok) return true;
    const lines = (await r.text()).split(/\r?\n/);
    let applies = false; const dis: string[] = [];
    for (const l of lines) {
      const [k, ...v] = l.split(':'); const val = v.join(':').trim(); const key = k.trim().toLowerCase();
      if (key === 'user-agent') applies = val === '*';
      else if (applies && key === 'disallow' && val) dis.push(val);
    }
    return !dis.some((d) => u.pathname.startsWith(d));
  } catch { return true; }
}

const PROC = /\b(RACPC|RASMECCC|RASMECC|SMECCC|SMECC|CPC|SULABH|HOME ?LOAN CENTRE|CREDIT CENTRE|RLMS|LCPC|CCPC|RAC|ULP|RETAIL ASSETS?|ASSET CENT\w*|PROCESSING|CENTRALI[SZ]ED|LOAN FACTORY|LOANS? POINT|LOAN HUB|MSME HUB|CREDIT HUB|RETAIL HUB|HUB)\b/;
const OFFICE = /\b(REGIONAL OFFICE|ZONAL OFFICE|HEAD OFFICE|HEADOFFICE|CORPORATE OFFICE|LOCAL HEAD OFFICE|CIRCLE OFFICE|ADMINISTRATIVE|RBO|ZO|RO|LHO|HO|REGIONAL BUSINESS OFFICE|TREASURY|CURRENCY CHEST|CURRENCY ADMINISTRATION|SERVICE BRANCH|SERVICE CENTRE|CLEARING|RTGS|NEFT|IMPS|GOVT BUSINESS|GOVERNMENT BUSINESS|TRADE FINANCE|FOREX|CASH MANAGEMENT|CMP|DIGITAL BANKING UNIT|NODAL|DEPARTMENT|ARCHIVAL|CORPORATE CENTRE)\b/;
const btype = (n: string) => { const u = n.toUpperCase(); return PROC.test(u) ? 'processing_centre' : OFFICE.test(u) ? 'office' : 'branch'; };
const STFIX: Record<string, string> = { 'MADHY PRADESH': 'MADHYA PRADESH', 'UTTARKHAND': 'UTTARAKHAND', 'ODHISA': 'ODISHA', 'DADAR AND NAGAR HAVELI': 'DADRA AND NAGAR HAVELI AND DAMAN AND DIU', 'LUDHIANA': 'PUNJAB', 'DAKSHIN KANNAD': 'KARNATAKA' };

function parseCsvLine(line: string): string[] {
  const out: string[] = []; let cur = ''; let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += c; }
    else if (c === '"') q = true; else if (c === ',') { out.push(cur); cur = ''; } else cur += c;
  }
  out.push(cur); return out;
}
const fmtDate = (iso: string) => { const d = new Date(iso); return `${d.getUTCDate()}-${['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][d.getUTCMonth()]}-${d.getUTCFullYear()}`; };

async function runBanks(t0: number, trigger: string, force: boolean) {
  const scope = await job({ op: 'scope' });
  const states = new Set<string>(scope.states);
  const fams: { family: string; ifsc_bank_code: string }[] = scope.families.filter((f: any) => f.ifsc_bank_code && f.primary_source === 'rbi_ifsc_directory');
  const code2fam = new Map(fams.map((f) => [f.ifsc_bank_code, f.family]));
  // latest release of the machine-readable directory
  const rel = await (await fetchRetry('https://api.github.com/repos/razorpay/ifsc/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })).json();
  const tag = String(rel.tag_name); const published = String(rel.published_at ?? rel.created_at);
  const asset = (rel.assets ?? []).find((a: any) => a.name === 'IFSC.csv');
  if (!asset) throw new Error('IFSC.csv not found in the latest release');
  const version = `RBI IFSC directory via razorpay/ifsc ${tag} (${fmtDate(published)})`;
  await job({ op: 'source_seen', source_key: 'rbi_ifsc_directory', url: asset.browser_download_url, version, published_at: published, status: 'ok' });
  const st = await job({ op: 'run_start', job: 'branch_monitor', trigger, source_version: version, force });
  if (st.skip) return { skipped: true, quiet: !!st.quiet, version };
  const run = st.run_id as number;
  const done = new Set<string>();
  if (st.busy) {
    const cur = await job({ op: 'run_status', run_id: run });
    for (const [k, v] of Object.entries(cur?.stats ?? {})) if ((v as any)?.complete) done.add(k);
  }
  const todo = fams.filter((f) => !done.has(f.family));
  if (!todo.length) return { run, version, note: 'all families already complete' };
  // sub-member (sublet) IFSCs belong to other banks
  const sub = await (await fetchRetry(`https://raw.githubusercontent.com/razorpay/ifsc/${tag}/src/sublet.json`)).json().catch(() => ({}));
  const csub = await (await fetchRetry(`https://raw.githubusercontent.com/razorpay/ifsc/${tag}/src/custom-sublets.json`)).json().catch(() => ({}));
  const csubKeys = Object.keys(csub);
  const want = new Set(todo.map((f) => f.ifsc_bank_code));
  const buf = new Map<string, any[]>(); const listed = new Map<string, number>(); const sent = new Map<string, number>();
  const errors: Record<string, unknown>[] = [];
  let stopped = false;
  const flush = async (fam: string, all = false) => {
    const b = buf.get(fam) ?? [];
    while (b.length >= 2000 || (all && b.length)) {
      const part = b.splice(0, 2000);
      await job({ op: 'apply', run_id: run, family: fam, source_type: 'rbi_ifsc_directory', source_version: version, source_url: asset.browser_download_url, source_label: 'RBI IFSC directory', rows: part });
      sent.set(fam, (sent.get(fam) ?? 0) + part.length);
    }
  };
  const res = await fetchRetry(asset.browser_download_url, {}, 3, 90000);
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let rest = ''; let header: string[] | null = null; let pending = '';
  const ix: Record<string, number> = {};
  const handle = async (line: string) => {
    if (!header) { header = parseCsvLine(line); header.forEach((h, i) => ix[h.trim()] = i); return; }
    const m = line.match(/,([A-Z]{4}0[A-Z0-9]{6}),/); if (!m) return;
    const code = m[1].slice(0, 4); if (!want.has(code)) return;
    const f = parseCsvLine(line); const ifsc = (f[ix.IFSC] ?? '').trim().toUpperCase();
    if (sub[ifsc] || csubKeys.some((k) => ifsc.startsWith(k))) return;
    // non-numeric branch part under a numeric-code bank = regional rural bank, co-op sub-member, collection or office code (Bank of Baroda uses letters)
    if (code !== 'BARB' && !/^[0-9]{6}$/.test(ifsc.slice(5))) return;
    const fam = code2fam.get(code)!; listed.set(fam, (listed.get(fam) ?? 0) + 1);
    let state = (f[ix.STATE] ?? '').trim().toUpperCase(); state = STFIX[state] ?? state;
    if (!states.has(state)) return;
    const name = (f[ix.BRANCH] ?? '').replace(/\s+/g, ' ').trim();
    const arr = buf.get(fam) ?? []; buf.set(fam, arr);
    arr.push({ uid: 'IFSC:' + ifsc, ifsc, code: ifsc.slice(5), micr: (f[ix.MICR] ?? '').trim() || null, name, address: (f[ix.ADDRESS] ?? '').replace(/\s+/g, ' ').trim() || null,
      district: (f[ix.DISTRICT] ?? '').trim().toUpperCase() || null, state, centre: (f[ix.CENTRE] ?? '').trim() || null, city: (f[ix.CITY] ?? '').trim() || null, branch_type: btype(name) });
    if (arr.length >= 2000 && !stopped) await flush(fam);
  };
  for (;;) {
    const { value, done: end } = await reader.read();
    if (value) rest += value;
    const lines = rest.split('\n'); rest = end ? '' : lines.pop()!;
    for (const raw of (end ? lines.concat(rest ? [rest] : []) : lines)) {
      const l = raw.replace(/\r$/, '');
      pending = pending ? pending + '\n' + l : l;
      if ((pending.split('"').length - 1) % 2 === 1) continue; // quoted field continues on next line
      await handle(pending); pending = '';
      if (Date.now() - t0 > BUDGET_MS) { stopped = true; break; }
    }
    if (end || stopped) break;
  }
  if (stopped) { try { await reader.cancel(); } catch { /* ignore */ } }
  const finished: string[] = [];
  for (const f of todo) {
    if (stopped) break; // incomplete read: never mark families complete or branches missing
    try {
      await flush(f.family, true);
      const r = await job({ op: 'finish_family', run_id: run, family: f.family, source_type: 'rbi_ifsc_directory', source_version: version, listed_total: listed.get(f.family) ?? 0 });
      finished.push(f.family);
      if (!r.ok && r.incomplete) errors.push({ family: f.family, error: 'source listed far fewer branches than expected; nothing marked missing' });
    } catch (e) {
      errors.push({ family: f.family, error: (e as Error).message.slice(0, 300) });
      await job({ op: 'finish_family', run_id: run, family: f.family, source_type: 'rbi_ifsc_directory', source_version: version, ok: false, error: { message: (e as Error).message.slice(0, 300) } }).catch(() => null);
    }
    if (Date.now() - t0 > BUDGET_MS + 25_000) { stopped = true; break; }
  }
  if (stopped) return { run, version, continuing: true, finished, note: 'time budget reached; the next scheduled tick continues this run' };
  const s = await job({ op: 'run_status', run_id: run });
  const tot = (k: string) => Object.values(s?.stats ?? {}).reduce((a: number, v: any) => a + (Number(v?.[k]) || 0), 0);
  const summary = `Compared ${fams.length} bank clients with ${version}: ${tot('added')} new, ${tot('updated')} changed, ${tot('newly_missing')} no longer listed (queued for review, not closed), ${tot('duplicate_candidates')} possible duplicates.`;
  const fin = await job({ op: 'run_finish', run_id: run, status: errors.length ? 'partial' : 'succeeded', errors, summary });
  return { run, version, status: fin.status, summary, errors };
}

async function checkWebsites(run: number | null) {
  const scope = await job({ op: 'scope' });
  const prev = await job({ op: 'source_get' });
  const out: Record<string, unknown>[] = [];
  for (const f of scope.families.filter((x: any) => x.primary_source === 'official_website' && x.locator_url)) {
    const key = 'web:' + f.family;
    try {
      const u = new URL(f.locator_url);
      if (!(await robotsAllows(u))) { await job({ op: 'source_seen', source_key: key, url: f.locator_url, status: 'robots_disallow', note: 'robots.txt disallows automated reading; checked manually only' }); out.push({ family: f.family, status: 'robots_disallow' }); continue; }
      const r = await fetchRetry(f.locator_url, {}, 2, 30000);
      const text = (await r.text()).replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
      const h = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))).map((b) => b.toString(16).padStart(2, '0')).join('');
      const old = prev?.[key]?.content_hash;
      await job({ op: 'source_seen', source_key: key, url: f.locator_url, content_hash: h, status: 'ok', note: `${text.length} characters of text` });
      if (old && old !== h) await job({ op: 'source_changed', family: f.family, run_id: run, evidence: { url: f.locator_url, previous_hash: old, new_hash: h } });
      out.push({ family: f.family, status: old ? (old === h ? 'unchanged' : 'changed') : 'baseline' });
    } catch (e) {
      await job({ op: 'source_seen', source_key: key, url: f.locator_url, status: 'error', note: (e as Error).message.slice(0, 300) }).catch(() => null);
      out.push({ family: f.family, status: 'error', error: (e as Error).message.slice(0, 200) });
    }
  }
  return out;
}

const RESEARCH_HOSTS = /(^|\.)(lichousing\.com|canfinhomes\.com|gichfindia\.com|pnbhousing\.com|tatacapital\.com|axisfinance\.in|nidohomefin\.com|tfsin\.co\.in|rbi\.org\.in)$/;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const t0 = Date.now();
  let body: any; try { body = await req.json(); } catch { return json({ error: 'invalid JSON' }, 400); }
  const token = req.headers.get('x-job-token') ?? body?.token;
  const auth = await rpc('bi_ai_gateway', { op: 'auth', token: String(token ?? ''), scopes: ['job', 'admin'] }).catch(() => ({ ok: false }));
  if (!auth.ok) return json({ error: 'job token or admin key required' }, 401);
  const action = String(body?.action ?? 'run');
  try {
    if (action === 'fetch') { // research helper: read one official page (allow-listed hosts, robots.txt respected); not a monitoring run
      try {
        const u = new URL(String(body.url));
        if (u.protocol !== 'https:' || !RESEARCH_HOSTS.test(u.hostname)) return json({ error: 'host not on the research allow-list' }, 400);
        if (!(await robotsAllows(u))) return json({ error: 'robots.txt disallows this path' }, 403);
        const r = await fetchRetry(u.toString(), { method: body.method === 'POST' ? 'POST' : 'GET', headers: body.headers ?? {}, body: body.body ?? undefined }, 2, 30000);
        const t = await r.text();
        return json({ status: r.status, content_type: r.headers.get('content-type'), length: t.length, text: t.slice(0, 1_500_000) });
      } catch (e) { return json({ error: (e as Error).message.slice(0, 300) }, 502); }
    }
    const banks = await runBanks(t0, String(body?.trigger ?? 'cron'), !!body?.force);
    const web = (banks as any).continuing || (banks as any).quiet ? [] : await checkWebsites((banks as any).run ?? null);
    return json({ banks, websites: web, ms: Date.now() - t0 });
  } catch (e) {
    const msg = (e as Error).message.slice(0, 400);
    // record the failure so it is visible in Data quality; the master is not marked current
    try {
      const st = await job({ op: 'run_start', job: 'branch_monitor', trigger: 'error', source_version: 'unavailable', force: true });
      if (st.run_id && !st.busy) await job({ op: 'run_finish', run_id: st.run_id, status: 'failed', errors: [{ error: msg }], summary: 'Monitoring run failed before comparing sources; branch master left unchanged.' });
    } catch { /* ignore */ }
    return json({ error: msg }, 500);
  }
});
