/* Crux BI — shared source extractor (browser + Node).
 * Converts a workbook into normalized, PII-free records. Interpretation of the
 * Zonal Tracker structure lives ONLY here; the database does dedup/derivation.
 * Timestamps: source cells are UTC wall-clock (verified from hour-of-day profile),
 * emitted as ISO strings with 'Z' — never via local-timezone Date parsing.
 */
(function (root) {
  'use strict';
  const XL = (c) => { let n = 0; for (const ch of c) n = n * 26 + ch.charCodeAt(0) - 64; return n - 1; };
  const COL = (i) => { let s = ''; i++; while (i) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; };
  const MON = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, june: 6, jul: 7, july: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
  const clean = (v) => (v == null ? null : String(v).replace(/\s+/g, ' ').trim() || null);
  const num = (v) => (v == null || v === '' || v === '-' ? null : (typeof v === 'number' ? v : (isFinite(+String(v).replace(/,/g, '')) ? +String(v).replace(/,/g, '') : null)));
  const serialToIso = (v) => {
    if (v == null || v === '' || v === '-') return null;
    if (typeof v === 'number') return new Date(Math.round((v - 25569) * 86400000)).toISOString();
    const s = String(v).trim();
    const m = s.match(/^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?/);
    if (m) return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6] || '00'}${m[7] ? m[7].slice(0, 4) : ''}Z`;
    return null;
  };

  // ---------- file classification ----------
  function detectCategory(wb) {
    const first = wb.SheetNames.map((n) => n.toLowerCase());
    if (first.includes('main tracker')) return 'zonal';
    const ws = wb.Sheets[wb.SheetNames[0]];
    const hdr = (rowValues(ws, 0) || []).map((h) => String(h || '').trim());
    if (hdr.includes('Point ID') && hdr.includes('Point Type')) return 'point';
    if (hdr.includes('Case ID') && hdr.includes('Received At')) return 'case';
    return detectFinance(wb);
  }

  // ---------- finance workbooks ----------
  // collection  = bank-statement credits tagged with location / client / invoice (one sheet per bank account, plus a consolidated "Main")
  // outstanding = dated snapshot of the open invoice ledger (one sheet per location group, plus a "Pvt" summary)
  // Only business fields are emitted. Applicant names, phone numbers, bank contact names, GST numbers, branch-name text (it sometimes holds a
  // borrower's name) and narration text never leave the browser; the "br" column is kept empty so the row layout stays stable
  // (narration is reduced to an 8-character fingerprint used only to spot the same credit entered twice).
  const lc = (v) => (v == null ? '' : String(v).replace(/\s+/g, ' ').trim().toLowerCase());
  const pad2 = (n) => String(n).padStart(2, '0');
  const yr = (s) => { const n = +s; return n < 100 ? 2000 + n : n; };
  const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return ('0000000' + h.toString(16)).slice(-8); };
  const cut = (v, n) => { const s = clean(v); return s && s.length > n ? s.slice(0, n) : s; };
  function sheetRows(ws) {
    const ref = ws && ws['!ref']; if (!ref) return [];
    const rg = root.XLSX.utils.decode_range(ref); const out = [];
    for (let r = 0; r <= rg.e.r; r++) out.push(rowValues(ws, r) || []);
    return out;
  }
  function headerAt(rows, pred, depth) { for (let i = 0; i < Math.min(depth || 8, rows.length); i++) if ((rows[i] || []).some((x) => pred(lc(x)))) return i; return -1; }
  function detectFinance(wb) {
    let credit = 0, outstanding = 0;
    for (const n of wb.SheetNames) {
      const rows = sheetRows(wb.Sheets[n]).slice(0, 8);
      if (headerAt(rows, (x) => x.startsWith('actual outstanding')) >= 0) outstanding++;
      const hi = headerAt(rows, (x) => x === 'credit');
      if (hi >= 0 && rows[hi].some((x) => /^invoice/.test(lc(x)))) credit++;
    }
    if (outstanding >= 1) return 'outstanding';
    if (credit >= 1) return 'collection';
    return null;
  }
  function finDate(v) { // -> 'YYYY-MM-DD' | null ; Indian day-first order for numeric dates
    if (v == null || v === '') return null;
    const ok = (y, m, d) => (m >= 1 && m <= 12 && d >= 1 && d <= 31 && y >= 2010 && y <= 2035 ? `${y}-${pad2(m)}-${pad2(d)}` : null);
    if (typeof v === 'number') return v > 30000 && v < 50000 ? new Date(Math.round((v - 25569) * 86400000)).toISOString().slice(0, 10) : null;
    if (v instanceof Date) return v.toISOString().slice(0, 10);
    const s = String(v).trim();
    let m = s.match(/^(\d{4})-(\d\d)-(\d\d)/); if (m) return ok(+m[1], +m[2], +m[3]);
    m = s.match(/^(\d{1,2})[\/\-. ]+([A-Za-z]{3,9})[\/\-. ,]+(\d{2,4})/); if (m) return ok(yr(m[3]), MON[m[2].toLowerCase().slice(0, 3)] || 0, +m[1]);
    m = s.match(/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})/); if (m) return ok(yr(m[3]), +m[2], +m[1]);
    return null;
  }
  function finMonth(v) { // -> 'YYYY-MM' | null
    if (v == null || v === '') return null;
    if (typeof v === 'number' || v instanceof Date) { const d = finDate(v); return d ? d.slice(0, 7) : null; }
    const s = lc(v);
    let m = s.match(/^(\d{4})-(\d\d)/); if (m) return +m[2] >= 1 && +m[2] <= 12 ? `${m[1]}-${m[2]}` : null;
    m = s.match(/^([a-z]{3,9})[\s\-'’.,]*(\d{2,4})$/); if (m && MON[m[1].slice(0, 3)]) return `${yr(m[2])}-${pad2(MON[m[1].slice(0, 3)])}`;
    const d = finDate(v); return d ? d.slice(0, 7) : null;
  }
    // invoice number -> canonical key PREFIX-YYMM-REST ; ym = month encoded in the number (when it is a valid month)
  function invParse(v) {
    const raw = clean(v); if (!raw) return null;
    let s = raw.toUpperCase().replace(/^[^A-Z0-9]+/, '').replace(/^CRUX[\s\-]*/, '');
    const multi = /[,&]|\bAND\b|\s\/\s/.test(s);
    s = s.split(/[,&]|\bAND\b|\s\/\s/)[0].trim().replace(/\s*-\s*|\s+/g, '-').replace(/-+/g, '-');
    const m = s.match(/^([A-Z]{2,5})-?(\d{2})(\d{2})-?([A-Z0-9][A-Z0-9\-]*)$/);
    if (!m) return { raw, key: s, prefix: (s.match(/^[A-Z]{2,5}/) || [null])[0], ym: null, multi, odd: true };
    const mm = +m[3];
    return { raw, key: `${m[1]}-${m[2]}${m[3]}-${m[4]}`, prefix: m[1], ym: mm >= 1 && mm <= 12 ? `20${m[2]}-${m[3]}` : null, multi, odd: false };
  }
  function nameMonth(fileName) { const m = String(fileName).match(/till\s*([A-Za-z]{3,9})[\s\-'’]*(\d{2,4})/i); return m && MON[m[1].toLowerCase().slice(0, 3)] ? `${yr(m[2])}-${pad2(MON[m[1].toLowerCase().slice(0, 3)])}` : null; }

  const COLL_COLS = ['r', 'loc', 'bank', 'rm', 'd', 'amt', 'cl', 'br', 'inv', 'basic', 'im', 'ims', 'h', 'pbc', 'pbn', 'ir'];
  /* Payer identity kept from a bank line (never the narration itself, which can carry customer names):
     pbc = payer branch code or IFSC, pbn = payer branch name, ir = an invoice number quoted in the narration ("INV NO ROMG 2609 1205" -> ROMG-2609-1205). */
  const IR_STOP = new Set(['NEFT', 'RTGS', 'IMPS', 'UPI', 'INB', 'CHQ', 'TRF', 'NACH', 'CMS', 'INV', 'NO', 'FROM', 'BY', 'TO', 'REF', 'UTR', 'ACH', 'ECS', 'BIL', 'ONL', 'MOB', 'CLG', 'OUTWARD', 'INWARD', 'DT', 'DATE', 'TXN', 'FT', 'IFT', 'BRN', 'CR', 'DR']);
  function invRef(t) {
    const s = String(t || '').toUpperCase(); const re = /\b([A-Z]{2,5})[\s\-\/]{0,2}(\d{2})(\d{2})[\s\-\/]{1,3}(\d{3,5})\b/g; let m;
    while ((m = re.exec(s))) { const yy = +m[2], mm = +m[3]; if (!IR_STOP.has(m[1]) && yy >= 23 && yy <= 30 && mm >= 1 && mm <= 12) return `${m[1]}-${m[2]}${m[3]}-${m[4]}`; }
    return null;
  }
  function extractCollection(wb, fileName) {
    const sheets = []; const issues = [];
    for (const name of wb.SheetNames) {
      const rows = sheetRows(wb.Sheets[name]);
      const hi = headerAt(rows, (x) => x === 'credit');
      if (hi < 0) { const gt = rows.find((r) => lc(r[0]) === 'grand total'); sheets.push({ sheet: name, role: 'summary', cols: [], rows: [], controls: { grand_total: gt ? num(gt[1]) : null } }); continue; }
      const h = rows[hi].map(lc);
      const idx = (pred, from) => { for (let i = from || 0; i < h.length; i++) if (pred(h[i], i)) return i; return -1; };
      const ci = idx((x) => x === 'credit');
      let im = idx((x) => x === 'month', ci + 1); if (im < 0) im = idx((x) => x === 'date', ci + 1); if (im < 0 && h[ci + 1] === '') im = ci + 1;
      const c = { loc: idx((x) => x === 'location'), bank: idx((x) => x === 'bank'), rm: idx((x) => x === 'month'),
        d: idx((x, i) => i < ci && ['date', 'txn date', 'date.', 'transaction date', 'value date'].includes(x)),
        cl: idx((x) => x === 'client', ci), br: idx((x) => x === 'branch', ci), inv: idx((x) => /^invoice( no\.?| number)?$/.test(x), ci), basic: idx((x) => x === 'basic', ci),
        nar: idx((x, i) => i < ci && ['narration', 'description', 'discription', 'details', 'remarks', 'particulars'].includes(x)), chq: idx((x, i) => i < ci && x.startsWith('cheque')), bc: idx((x, i) => i < ci && x === 'branch code'), bcn: idx((x, i) => i < ci && x === 'branch code with name'), bnm: idx((x, i) => i < ci && x === 'branch name'), ifsc: idx((x) => x === 'ifsc'), im };
      const out = []; const ctl = { rows: 0, credit: 0, by_month: {}, min_date: null, max_date: null, with_invoice: 0, invoice_credit: 0, ym_number_vs_column_differ: 0, odd_invoice: 0, multi_invoice: 0, no_receipt_month: 0 };
      for (let r = hi + 1; r < rows.length; r++) {
        const row = rows[r]; const amt = num(row[ci]); if (amt == null) continue;
        const d = c.d >= 0 ? finDate(row[c.d]) : null; const rm = (c.rm >= 0 ? finMonth(row[c.rm]) : null) || (d ? d.slice(0, 7) : null);
        const iv = c.inv >= 0 ? invParse(row[c.inv]) : null; const colYm = c.im >= 0 ? finMonth(row[c.im]) : null;
        let ym = null, ims = null; if (iv && iv.ym) { ym = iv.ym; ims = 'n'; if (colYm && colYm !== iv.ym) ctl.ym_number_vs_column_differ++; } else if (colYm) { ym = colYm; ims = 'c'; }
        const fp = fnv([c.nar >= 0 ? lc(row[c.nar]) : '', c.chq >= 0 ? lc(row[c.chq]) : '', c.bc >= 0 ? lc(row[c.bc]) : '', d || lc(row[c.d]), amt].join('|'));
        const bcn = c.bcn >= 0 ? String(row[c.bcn] == null ? '' : row[c.bcn]).match(/^\s*(\d{1,6})\s*-\s*(.+)$/) : null;
        const ifsc = c.ifsc >= 0 ? String(row[c.ifsc] == null ? '' : row[c.ifsc]).trim().toUpperCase() : '';
        const code = c.bc >= 0 ? String(row[c.bc] == null ? '' : row[c.bc]).replace(/\.0+$/, '').trim() : '';
        const pbc = /^[A-Z]{4}0[A-Z0-9]{6}$/.test(ifsc) ? ifsc : /^\d{1,6}$/.test(code) ? code : bcn ? bcn[1] : null;
        const pbn = bcn ? cut(bcn[2], 40) : c.bnm >= 0 ? cut(row[c.bnm], 40) : null;
        out.push([r + 1, cut(row[c.loc], 40), cut(row[c.bank], 30), rm, d, amt, cut(row[c.cl], 30), c.br >= 0 ? cut(row[c.br], 40) : null, iv ? cut(iv.raw, 40) : null, c.basic >= 0 ? num(row[c.basic]) : null, ym, ims, fp,
          pbc, pbn, iv ? null : (c.nar >= 0 ? invRef(row[c.nar]) : null)]);
        ctl.rows++; ctl.credit += amt; if (rm) ctl.by_month[rm] = (ctl.by_month[rm] || 0) + amt; else ctl.no_receipt_month++;
        if (d) { if (!ctl.min_date || d < ctl.min_date) ctl.min_date = d; if (!ctl.max_date || d > ctl.max_date) ctl.max_date = d; }
        if (iv) { ctl.with_invoice++; ctl.invoice_credit += amt; if (iv.odd) ctl.odd_invoice++; if (iv.multi) ctl.multi_invoice++; }
      }
      ctl.credit = Math.round(ctl.credit * 100) / 100; ctl.invoice_credit = Math.round(ctl.invoice_credit * 100) / 100;
      for (const k in ctl.by_month) ctl.by_month[k] = Math.round(ctl.by_month[k] * 100) / 100;
      sheets.push({ sheet: name, role: lc(name) === 'main' ? 'main' : 'bank', cols: COLL_COLS, rows: out, controls: ctl });
    }
    const bank = sheets.filter((s) => s.role === 'bank');
    const months = [...new Set(bank.flatMap((s) => Object.keys(s.controls.by_month)))].sort();
    const maxDate = bank.map((s) => s.controls.max_date).filter(Boolean).sort().pop() || null;
    const nm = nameMonth(fileName);
    if (nm && months.length && months[months.length - 1] > nm) issues.push({ rule: 'receipts_after_name_period', severity: 'info', detail: `File is named up to ${nm} but contains receipts up to ${maxDate || months[months.length - 1]}; the last month is treated as partial.` });
    const main = sheets.find((s) => s.role === 'main');
    if (main) {
      const mm = Object.keys(main.controls.by_month).sort(); const diff = {};
      for (const k of mm) { const b = bank.reduce((a, s) => a + (s.controls.by_month[k] || 0), 0); diff[k] = { main: main.controls.by_month[k], bank_sheets: Math.round(b * 100) / 100, difference: Math.round((main.controls.by_month[k] - b) * 100) / 100 }; }
      main.controls.vs_bank_sheets = diff;
      if (mm.length && mm.length < months.length) issues.push({ rule: 'main_sheet_partial', severity: 'info', detail: `"Main" covers only ${mm.join(', ')}; the bank-account sheets cover ${months[0]} to ${months[months.length - 1]} and are used as the receipt ledger (Main is a cross-check only, never added).` });
    }
    return { kind: 'collection', file_name: fileName, name_period: nm, period_from: months[0] ? months[0] + '-01' : null, period_to: months.length ? months[months.length - 1] + '-01' : null, data_through: maxDate, sheets, issues };
  }

  const OS_COLS = ['r', 'loc', 'im', 'ims', 'cl', 'br', 'inv', 'basic', 'gross', 'tds', 'net', 'partial', 'os', 'rk'];
  function extractOutstanding(wb, fileName) {
    const sheets = []; const issues = []; let asOn = null;
    for (const name of wb.SheetNames) {
      const rows = sheetRows(wb.Sheets[name]);
      // wave 098: an "As on" date written near the top of any sheet (the template puts it on the summary sheet) is the snapshot date
      if (!asOn) for (let i = 0; i < Math.min(6, rows.length) && !asOn; i++) { const x = rows[i] || []; for (let j = 0; j < x.length - 1; j++) if (/^(as on|as at|as on date|snapshot date)\b/.test(lc(x[j]))) { const d = finDate(x[j + 1]); if (d) { asOn = d; break; } } }
      let hi = headerAt(rows, (x) => x.startsWith('actual outstanding'));
      if (hi >= 0 && !rows[hi].some((x) => /^inv/.test(lc(x)))) hi = -1; // no invoice column: a summary sheet
      if (hi < 0) { // location summary sheet ("Pvt")
        const sh = headerAt(rows, (x) => /^total ou?t?standing|^total oustanding/.test(x));
        const sum = [], adj = []; if (sh >= 0) for (let r = sh + 1; r < rows.length; r++) { const x = rows[r];
          if (clean(x[0])) sum.push({ label: clean(x[0]), total: num(x[1]), unadj: num(x[2]), net: num(x[3]), remark: cut(x[4], 30) });
          else { const lab = [2, 1].map((i) => (typeof x[i] === 'string' ? clean(x[i]) : null)).find(Boolean); const amt = num(x[3]); if (lab && amt != null) adj.push({ label: cut(lab, 40), amount: amt }); } }
        sheets.push({ sheet: name, role: 'summary', cols: [], rows: [], controls: { summary: sum, adjustments: adj } }); continue;
      }
      const h = rows[hi].map(lc);
      const idx = (pred, from) => { for (let i = from || 0; i < h.length; i++) if (pred(h[i], i)) return i; return -1; };
      const ao = idx((x) => x.startsWith('actual outstanding')); const pr = idx((x) => x.startsWith('partial'));
      const inv = idx((x) => /^inv/.test(x)); const mo = idx((x) => x === 'month'); const cl = idx((x) => x === 'client' || x === 'clinet', mo + 1);
      const basic = idx((x) => x === 'basic'); const gross = idx((x) => x === 'gross'); const tds = idx((x) => x === 'tds');
      let net = idx((x) => x === 'net'); if (net < 0 && tds >= 0) net = tds + 1; const rk = idx((x) => x.startsWith('remark') || x === 'status');
      const br = cl >= 0 ? cl + 1 : -1;
      const out = []; const ctl = { rows: 0, basic: 0, net: 0, partial: 0, os: 0, negative_rows: 0, no_invoice_rows: 0, month_from_number: 0, sheet_total: null, unadj: [], net_control: null, month_differs_from_number: 0 };
      let totalsSeen = false;
      for (let r = hi + 1; r < rows.length; r++) {
        const row = rows[r]; const osv = num(row[ao]); const invRaw = clean(row[inv]);
        const isLine = !!invRaw || (!totalsSeen && (clean(row[mo]) || clean(row[cl])) && (osv != null || num(row[basic]) != null));
        if (isLine) {
          // invoice month: the month encoded in the (system-generated) invoice number; the typed Month column only when the number has none
          const iv = invParse(row[inv]); const colYm = finMonth(row[mo]); let im = null, ims = null;
          if (iv && iv.ym) { im = iv.ym; ims = 'n'; ctl.month_from_number++; if (colYm && colYm !== iv.ym) ctl.month_differs_from_number++; }
          else if (colYm) { im = colYm; ims = 'c'; }
          const line = [r + 1, cut(row[0], 40), im, ims, cut(row[cl], 40), null, iv ? cut(iv.raw, 40) : null, num(row[basic]), num(row[gross]), num(row[tds]), num(row[net]), num(row[pr]) || 0, osv == null ? 0 : osv, cut(row[rk], 40)];
          out.push(line); ctl.rows++; ctl.basic += line[7] || 0; ctl.net += line[10] || 0; ctl.partial += line[11] || 0; ctl.os += line[12];
          if (line[12] < 0) ctl.negative_rows++; if (!iv) ctl.no_invoice_rows++;
          continue;
        }
        if (osv == null) continue;
        if (!totalsSeen && num(row[basic]) != null) { totalsSeen = true; ctl.sheet_total = { basic: num(row[basic]), gross: num(row[gross]), tds: num(row[tds]), net: num(row[net]), partial: num(row[pr]), os: osv }; continue; }
        const label = clean(row[pr]) || clean(row[ao - 1]) || '';
        if (/total|outstanding as|o\/s as/i.test(label)) ctl.net_control = { label: cut(label, 40), amount: osv };
        else ctl.unadj.push({ label: cut(label, 40), amount: osv });
      }
      for (const k of ['basic', 'net', 'partial', 'os']) ctl[k] = Math.round(ctl[k] * 100) / 100;
      if (ctl.sheet_total && Math.abs(ctl.sheet_total.os - ctl.os) > 1) issues.push({ rule: 'sheet_total_mismatch', severity: 'warn', sheet: name, detail: `Lines add to ${ctl.os.toFixed(2)} but the sheet's total row says ${ctl.sheet_total.os.toFixed(2)}.` });
      if (ctl.net_control) { const un = ctl.unadj.reduce((a, u) => a + (/unadj/i.test(u.label) || ctl.unadj.length === 1 ? u.amount : 0), 0) || ctl.unadj.reduce((a, u) => a + u.amount, 0); const expect = (ctl.sheet_total ? ctl.sheet_total.os : ctl.os) - un; if (Math.abs(expect - ctl.net_control.amount) > 1) issues.push({ rule: 'net_control_mismatch', severity: 'warn', sheet: name, detail: `Sheet total less unadjusted receipts = ${expect.toFixed(2)}, but the sheet shows ${ctl.net_control.amount.toFixed(2)}.` }); }
      sheets.push({ sheet: name, role: 'ledger', cols: OS_COLS, rows: out, controls: ctl });
    }
    const nm = nameMonth(fileName);
    const summ = sheets.find((s) => s.role === 'summary');
    if (summ && summ.controls.summary.length) {
      const tot = summ.controls.summary.find((x) => /^total$/i.test(x.label)); const led = sheets.filter((s) => s.role === 'ledger');
      const ledTotal = led.reduce((a, s) => a + (s.controls.sheet_total ? s.controls.sheet_total.os : s.controls.os), 0);
      if (tot && Math.abs(tot.total - ledTotal) > 1) issues.push({ rule: 'summary_vs_sheets', severity: 'warn', detail: `Summary sheet total ${tot.total.toFixed(2)} vs location sheets ${ledTotal.toFixed(2)} (difference ${(ledTotal - tot.total).toFixed(2)}).` });
    }
    return { kind: 'outstanding', file_name: fileName, name_period: nm, as_on: asOn, sheets, issues };
  }
  function rowValues(ws, r) {
    const ref = ws['!ref']; if (!ref) return null;
    const rg = root.XLSX.utils.decode_range(ref); const out = [];
    const dense = ws['!data'];
    for (let c = 0; c <= rg.e.c; c++) {
      const cell = dense ? (dense[r] || [])[c] : ws[root.XLSX.utils.encode_cell({ r, c })];
      out.push(cell ? cell.v : null);
    }
    return out;
  }
  function parseNameMeta(fileName) {
    const base = fileName.replace(/\.xlsx?$/i, '');
    const asOn = base.match(/As on (\d{1,2}) ([A-Za-z]+) (\d{4})/i);
    let snapshot = null;
    if (asOn) { const m = MON[asOn[2].toLowerCase().slice(0, asOn[2].toLowerCase().startsWith('sept') ? 4 : 3)]; if (m) snapshot = `${asOn[3]}-${String(m).padStart(2, '0')}-${asOn[1].padStart(2, '0')}`; }
    const mm = base.match(/_([A-Za-z]+)(?:\s*\(\d+\))?$/);
    const monthToken = mm ? mm[1].toLowerCase() : null;
    const group = mm ? base.slice(0, mm.index).replace(/[_\s]+/g, ' ').trim() : base;
    return { snapshot, monthToken, group };
  }

  // ---------- Case / Point (row-per-record sources) ----------
  const CASE_MAP = { 'Case ID': 'case_id', 'Client': 'client', 'Branch': 'branch', 'Branch Code': 'branch_code', 'Branch Type': 'branch_type', 'Area Office': 'area_office', 'Status': 'status', 'Received At': 'received_at', 'Completed At': 'completed_at', 'Estimated TAT': 'due_at', 'Product': 'product', 'Points': 'points' };
  const POINT_MAP = { 'Point ID': 'point_id', 'Case ID': 'case_id', 'Branch': 'branch', 'Client Code': 'client_code', 'Branch Type': 'branch_type', 'Area Office': 'area_office', 'User Type': 'user_type', 'Point Type': 'point_type', 'Created By': 'created_by', 'Created Date': 'created_at', 'Assign To': 'assign_to', 'Status': 'status', 'Report Status': 'report_status', 'Verified By': 'verified_by', 'Completed By': 'completed_by', 'Assign Date': 'assigned_at', 'Field Reviewed Date': 'field_reviewed_at', 'Completed Date': 'completed_at', 'Pincode': 'pincode', 'Product': 'product' };
  const DATE_FIELDS = new Set(['received_at', 'completed_at', 'due_at', 'created_at', 'assigned_at', 'field_reviewed_at']);
  // Deliberately NOT extracted (PII, not needed for any KPI): Applicant Name, Mobile, PAN, Aadhaar, Bank A/c, Reference/Application/Quotation/Consumer/Property/Employee numbers. Address -> has_address flag only.
  function extractRecords(wb, map, kind) {
    const out = []; const issues = [];
    for (const sn of wb.SheetNames) {
      const rows = root.XLSX.utils.sheet_to_json(wb.Sheets[sn], { header: 1, raw: true, defval: null });
      if (!rows.length) continue;
      const hdr = rows[0].map((h) => String(h || '').trim());
      const idx = {}; hdr.forEach((h, i) => { if (map[h]) idx[map[h]] = i; });
      const addrIdx = hdr.indexOf('Address');
      const need = kind === 'case' ? ['case_id', 'received_at'] : ['point_id', 'case_id'];
      for (const n of need) if (idx[n] == null) issues.push({ rule: 'missing_required_column', detail: { sheet: sn, column: n } });
      for (let r = 1; r < rows.length; r++) {
        const row = rows[r]; if (!row || row.every((v) => v == null || v === '')) continue;
        const o = {};
        for (const [k, i] of Object.entries(idx)) {
          const v = row[i];
          o[k] = DATE_FIELDS.has(k) ? serialToIso(v) : clean(v);
        }
        if (kind === 'point') {
          const a = addrIdx >= 0 ? clean(row[addrIdx]) : null; o.has_address = !!(a && a !== '-');
          if (o.pincode && !/^\d{6}$/.test(o.pincode)) o.pincode_raw_invalid = true;
        }
        o._src_row = r + 1;
        out.push(o);
      }
    }
    return { rows: out, issues };
  }

  // ---------- Zonal tracker (Main Tracker only) ----------
  function decodeMonthHeader(v) {
    // Excel converted typed "Sep-24" into 24-Sep-<entry year>; i.e. day encodes the year.
    if (v == null) return null;
    if (typeof v === 'number') {
      const d = new Date(Math.round((v - 25569) * 86400000));
      const day = d.getUTCDate(), mon = d.getUTCMonth() + 1;
      const year = day === 1 ? d.getUTCFullYear() : 2000 + day;
      return { year, month: mon, how: day === 1 ? 'date_as_is' : 'day_encodes_year' };
    }
    const s = String(v).trim().toLowerCase();
    const m = s.match(/^([a-z]+)['\- ]?(\d{2,4})$/);
    if (m && MON[m[1].slice(0, m[1].startsWith('sept') ? 4 : 3)] ) {
      const y = +m[2] < 100 ? 2000 + +m[2] : +m[2];
      return { year: y, month: MON[m[1].slice(0, m[1].startsWith('sept') ? 4 : 3)], how: 'text' };
    }
    return null;
  }
  function headerMonthText(t) {
    if (!t) return null; const s = String(t).toLowerCase().replace(/\s+/g, ' ');
    const m = s.match(/(jan|feb|mar|apr|may|june|jun|july|jul|aug|sept|sep|oct|nov|dec)[a-z]*\s*'?\s*(\d{2})\b/);
    return m ? { month: MON[m[1].slice(0, m[1].startsWith('sept') ? 4 : 3)] || MON[m[1]], year: 2000 + +m[2] } : null;
  }

  function extractZonal(wb, fileName) {
    const ws = wb.Sheets['Main Tracker'];
    if (!ws) throw new Error('Main Tracker sheet not found');
    const XU = root.XLSX.utils; const rg = XU.decode_range(ws['!ref']);
    const cell = (r, c) => ws[XU.encode_cell({ r, c })];
    const val = (r, c) => { const x = cell(r, c); return x ? x.v : null; };
    const fml = (r, c) => { const x = cell(r, c); return x && x.f ? String(x.f) : null; };
    const issues = [];
    const meta = parseNameMeta(fileName);
    // report month from D3 header "Target \nOct 26"
    const rm = headerMonthText(val(2, 3));
    const report_month = rm ? `${rm.year}-${String(rm.month).padStart(2, '0')}-01` : null;
    // snapshot date: file name, cross-checked with O3 "09.10.2026"
    let o3 = val(2, 14); let o3date = null;
    if (typeof o3 === 'number') o3date = serialToIso(o3).slice(0, 10);
    else if (o3 && /^\d{2}\.\d{2}\.\d{4}$/.test(String(o3).trim())) { const [d, m, y] = String(o3).trim().split('.'); o3date = `${y}-${m}-${d}`; }
    const snapshot_date = meta.snapshot || o3date;
    if (meta.snapshot && o3date && meta.snapshot !== o3date) issues.push({ rule: 'snapshot_date_mismatch', severity: 'warning', detail: { file_name_date: meta.snapshot, column_o_header: o3date } });

    // ---- historical month columns (from column P onward) ----
    const histCols = []; // {col, year, month, measure}
    let cur = null;
    for (let c = XL('P'); c <= rg.e.c; c++) {
      const h1 = val(0, c), h3 = val(2, c);
      const dm = decodeMonthHeader(h1);
      if (dm) cur = { year: dm.year, month: dm.month, how: dm.how, startCol: c, n: 0, hdrText: [] };
      if (!cur) continue;
      const t = String(h3 || '').toLowerCase().replace(/\s+/g, ' ').trim();
      let measure = null;
      if (/^(actual mtd|target mtd)$/.test(t) || /^[a-z]{3,5}-?\d{2}$/.test(t) || typeof h3 === 'number') measure = 'cases';
      else if (/revenue/.test(t)) measure = 'revenue';
      else if (/billing/.test(t)) measure = 'billing';
      if (measure && cur.n < 3) {
        histCols.push({ col: c, year: cur.year, month: cur.month, measure, header: h3 == null ? null : String(h3) });
        cur.n++;
        const hm = headerMonthText(h3);
        if (hm && (hm.month !== cur.month || hm.year !== cur.year)) issues.push({ rule: 'history_header_month_conflict', severity: 'info', detail: { column: COL(c), row1_month: `${cur.year}-${cur.month}`, row3_text: String(h3) } });
      }
    }

    // ---- classify rows ----
    const rows = []; let zone = null; let zoneHasRollup = false; let inSummary = false; let section = 'main';
    for (let r = 3; r <= rg.e.r; r++) {
      const A = clean(val(r, 0)), B = clean(val(r, 1)), C = clean(val(r, 2));
      const D = val(r, 3), E = val(r, 4); const fE = fml(r, 4);
      if (A == null && B == null && C == null && D == null && E == null) continue;
      if (/client wise business count/i.test(String(D || ''))) { section = 'client'; continue; }
      if (/operation stakeholders wise/i.test(String(C || ''))) { section = 'stakeholder'; continue; }
      if (section !== 'main' || inSummary || ['Zone A', 'Zone B'].includes(A) && B == null) {
        if (['Zone A', 'Zone B'].includes(A)) inSummary = true;
        if (!inSummary && section === 'main') continue;
        const label = section === 'main' ? A : C;
        if (label == null || /^target|^operation stakeholders$|^client$/i.test(label) || num(D) == null) continue;
        rows.push(zRow(r, section === 'main' ? 'summary' : section === 'client' ? 'client_summary' : 'stakeholder_summary', null, label, null));
        continue;
      }
      if (A && B == null && D == null && E == null) { zone = A; zoneHasRollup = false; continue; }          // zone header
      if (A === 'Location' && B === 'Client') continue;                              // repeated header
      if (A && /^total\b/i.test(A)) { rows.push(zRow(r, 'location_total', zone, A.replace(/^total\s*/i, ''), B)); if (!zoneHasRollup) zone = null; continue; }
      if (fE && /SUMIF/i.test(fE)) { zoneHasRollup = true; rows.push(zRow(r, 'zone_client_rollup', zone, A, B)); continue; }
      if (A && B) { rows.push(zRow(r, 'leaf', zone || A, A, B)); continue; }
      issues.push({ rule: 'unclassified_row', severity: 'warning', detail: { row: r + 1, A, B } });
    }
    // distinguish zone totals: a total whose SUM range covers rollup rows
    const byRow = new Map(rows.map((x) => [x.sheet_row, x]));
    for (const x of rows) if (x.row_type === 'location_total') {
      const f = x._fE || ''; const m = f.match(/SUM\(E(\d+):E(\d+)\)/i);
      if (m) { for (let k = +m[1]; k <= +m[2]; k++) { const y = byRow.get(k); if (y && y.row_type === 'zone_client_rollup') { x.row_type = 'zone_total'; break; } } }
    }
    function zRow(r, type, zoneLabel, loc, client) {
      const fO = fml(r, 14), fE = fml(r, 4), fG = fml(r, 6);
      let rate = null; const mg = fG && fG.match(/^E\d+\*([\d.]+)$/); if (mg) rate = +mg[1];
      let prev = null; const mo = fO && fO.match(/^[EG]\d+-([\d.]+)$/); if (mo) prev = +mo[1];
      const o = {
        sheet_row: r + 1, row_type: type, zone_group: zoneLabel, location_label: loc, client_label: client,
        region_label: clean(val(r, 2)),
        target_cases: num(val(r, 3)), mtd_cases: num(val(r, 4)), revenue_target: num(val(r, 5)), revenue_actual: num(val(r, 6)),
        achievement: num(val(r, 7)), bd_revenue: num(val(r, 9)), shortfall_revenue: num(val(r, 10)),
        expense_projected: num(val(r, 11)), margin_after_expense: num(val(r, 12)), col_n_value: num(val(r, 13)),
        src_daily_value: num(val(r, 14)), src_prev_value: prev, rate,
        e_formula_kind: fE ? (/SUMIF/i.test(fE) ? 'sumif' : /SUM\(/i.test(fE) ? 'sum' : /^[\d+\s]+$/.test(fE.replace(/=/g, '')) ? 'addition' : 'other') : 'constant',
        _fE: fE,
        hist_location_label: clean(val(r, XL('P'))), hist_client_label: clean(val(r, XL('Q'))),
      };
      if (type === 'leaf') o.history = histCols.map((h) => ({ y: h.year, m: h.month, k: h.measure, c: COL(h.col), v: num(val(r, h.col)) })).filter((h) => h.v != null);
      if ((type === 'stakeholder_summary' || type === 'summary') && fE) o.member_total_rows = (fE.match(/E(\d+)/g) || []).map((s) => +s.slice(1));
      return o;
    }
    const pan = rows.find((x) => x.row_type === 'summary' && /^pan india$/i.test(x.location_label));
    return { kind: 'zonal', snapshot_date, report_month, file_name: fileName, rows: rows.map(({ _fE, ...x }) => x), hist_columns: histCols.length, control: pan ? { target: pan.target_cases, mtd: pan.mtd_cases } : null, issues };
  }

  function extractWorkbook(wb, fileName) {
    const cat = detectCategory(wb);
    const meta = parseNameMeta(fileName);
    if (cat === 'zonal') return extractZonal(wb, fileName);
    if (cat === 'case') { const x = extractRecords(wb, CASE_MAP, 'case'); return { kind: 'case', file_name: fileName, group: meta.group, month_token: meta.monthToken, ...x }; }
    if (cat === 'point') { const x = extractRecords(wb, POINT_MAP, 'point'); return { kind: 'point', file_name: fileName, group: meta.group, month_token: meta.monthToken, ...x }; }
    if (cat === 'collection') return extractCollection(wb, fileName);
    if (cat === 'outstanding') return extractOutstanding(wb, fileName);
    return { kind: null, file_name: fileName, issues: [{ rule: 'unrecognised_file', severity: 'error' }] };
  }
  const api = { extractWorkbook, detectCategory, parseNameMeta, decodeMonthHeader, serialToIso, invParse, finDate, finMonth };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.CruxExtract = api;
})(typeof window !== 'undefined' ? window : (global.XLSX = global.XLSX || require('xlsx'), global));
