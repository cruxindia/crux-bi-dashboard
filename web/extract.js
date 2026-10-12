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
    return null;
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
    return { kind: null, file_name: fileName, issues: [{ rule: 'unrecognised_file', severity: 'error' }] };
  }
  const api = { extractWorkbook, detectCategory, parseNameMeta, decodeMonthHeader, serialToIso };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.CruxExtract = api;
})(typeof window !== 'undefined' ? window : (global.XLSX = global.XLSX || require('xlsx'), global));
