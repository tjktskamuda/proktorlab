// Emulator Google Apps Script sederhana untuk menguji apps-script/Code.gs + Agen.gs di komputer sendiri.
// Pakai: node tools/gasmock.js [port]   -> backend palsu di http://127.0.0.1:PORT/exec
// Meniru perilaku asli: respons /exec dialihkan (302) ke URL lain dan diberi header CORS.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const http = require('http');
const crypto = require('crypto');
const url = require('url');

const SRC = path.join(__dirname, '..', 'apps-script');
const PORT = Number(process.argv[2] || 8787);

// ---------- Spreadsheet ----------
// Meniru Google Sheets berlokal Indonesia: teks yang ditulis ke sel berformat
// otomatis diubah jadi tanggal/angka ("1.5.0" -> 1 Mei 2000, "192.168.100.255"
// -> 192168100255), kecuali selnya berformat teks biasa ('@').
const stats0 = { epWrites: 0 };
function coerce(sheet, row, col, v) {
  if (typeof v !== 'string') return v;
  if (sheet.fmt[row + ':' + col] === '@') return v;
  const s = v.trim();
  const m = s.match(/^(\d{1,2})[.\/-](\d{1,2})[.\/-](\d{1,4})$/);
  if (m) {
    const d = +m[1], mo = +m[2];
    let y = +m[3];
    if (m[3].length <= 2) y += y < 30 ? 2000 : 1900;
    const dt = new Date(y, mo - 1, d);
    if (mo >= 1 && mo <= 12 && d >= 1 && dt.getMonth() === mo - 1) return dt;
  }
  if (/^-?\d{1,3}(\.\d{3})+$/.test(s)) return Number(s.replace(/\./g, ''));
  if (/^-?\d{1,14}$/.test(s)) return Number(s);
  return v;
}
function colToNum(c) { let n = 0; for (const ch of c) n = n * 26 + (ch.charCodeAt(0) - 64); return n; }
class Range {
  constructor(sheet, r, c, nr, nc) { Object.assign(this, { sheet, r, c, nr, nc }); }
  getValues() {
    const out = [];
    for (let i = 0; i < this.nr; i++) {
      const row = this.sheet.data[this.r - 1 + i] || [];
      const o = [];
      for (let j = 0; j < this.nc; j++) { const v = row[this.c - 1 + j]; o.push(v === undefined ? '' : v); }
      out.push(o);
    }
    return out;
  }
  getValue() { return this.getValues()[0][0]; }
  setValues(v) {
    if (v.length !== this.nr || v[0].length !== this.nc) throw new Error(`setValues dims mismatch ${v.length}x${v[0].length} vs ${this.nr}x${this.nc}`);
    for (let i = 0; i < this.nr; i++) {
      const ri = this.r - 1 + i;
      while (this.sheet.data.length <= ri) this.sheet.data.push([]);
      for (let j = 0; j < this.nc; j++) this.sheet.data[ri][this.c - 1 + j] = coerce(this.sheet, ri + 1, this.c + j, v[i][j]);
    }
    if (this.sheet.name === 'Endpoint') stats0.epWrites++;
    return this;
  }
  setNumberFormat(f) {
    for (let i = 0; i < this.nr; i++) for (let j = 0; j < this.nc; j++) this.sheet.fmt[(this.r + i) + ':' + (this.c + j)] = f;
    return this;
  }
  setValue(v) { return this.setValues([[v]]); }
  setFontWeight() { return this; } setBackground() { return this; } setFontColor() { return this; }
  getRow() { return this.r; }
  createTextFinder(text) {
    const self = this; let entire = false;
    const find = () => {
      const res = [];
      const lastRow = self.sheet.getLastRow();
      for (let i = 0; i < lastRow; i++) for (let j = 0; j < self.nc; j++) {
        const v = String((self.sheet.data[i] || [])[self.c - 1 + j] ?? '');
        if (entire ? v === text : v.includes(text)) res.push(new Range(self.sheet, i + 1, self.c + j, 1, 1));
      }
      return res;
    };
    const tf = { matchEntireCell(b) { entire = b; return tf; }, findNext() { return find()[0] || null; }, findAll() { return find(); } };
    return tf;
  }
}
class Sheet {
  constructor(name) { this.name = name; this.data = []; this.fmt = {}; }
  getLastRow() { let n = this.data.length; while (n > 0 && (!this.data[n - 1] || this.data[n - 1].every(v => v === '' || v === undefined))) n--; return n; }
  getRange(a, b, c, d) {
    if (typeof a === 'string') { const m = a.match(/^([A-Z]+):([A-Z]+)$/); const c1 = colToNum(m[1]); return new Range(this, 1, c1, Math.max(this.getLastRow(), 1), colToNum(m[2]) - c1 + 1); }
    if (a < 1 || b < 1) throw new Error('range out of bounds');
    return new Range(this, a, b, c || 1, d || 1);
  }
  appendRow(row) {
    const n = this.getLastRow(); this.data.length = n;
    this.data.push(row.map((v, j) => coerce(this, n + 1, j + 1, v)));
    if (this.name === 'Endpoint') stats0.epWrites++;
    return this;
  }
  getMaxRows() { return Math.max(this.maxRows || 0, this.data.length); }
  insertRowsAfter(after, n) { this.maxRows = this.getMaxRows() + n; this.inserted = (this.inserted || 0) + n; }
  deleteRows(start, n) { this.data.splice(start - 1, n); }
  deleteRow(r) { this.data.splice(r - 1, 1); }
  setFrozenRows() {}
}
const sheets = {};
const ss = {
  getSheetByName: n => sheets[n] || null,
  insertSheet: n => (sheets[n] = new Sheet(n)),
  getSpreadsheetTimeZone: () => 'Asia/Makassar',
  getSpreadsheetLocale: () => 'in_ID',
};

// ---------- Properties / Cache / Lock ----------
const propStore = {};
const stats = { propRead: 0, propWrite: 0, post: 0 };
const props = {
  getProperty: k => { stats.propRead++; return (k in propStore ? propStore[k] : null); },
  setProperty: (k, v) => { stats.propWrite++; if (String(v).length > 9216) throw new Error('prop too large ' + k); propStore[k] = String(v); return props; },
  deleteProperty: k => { delete propStore[k]; return props; },
  getKeys: () => Object.keys(propStore),
};
const cacheStore = {};
const cache = {
  get: k => { const e = cacheStore[k]; if (!e) return null; if (e.exp < Date.now()) { delete cacheStore[k]; return null; } return e.v; },
  put: (k, v, ttl) => { if (String(v).length > 100000) throw new Error('cache value too large'); cacheStore[k] = { v: String(v), exp: Date.now() + (ttl || 600) * 1000 }; },
  remove: k => { delete cacheStore[k]; },
  removeAll: ks => { ks.forEach(k => delete cacheStore[k]); },
  getAll: keys => { const o = {}; keys.forEach(k => { const v = cache.get(k); if (v != null) o[k] = v; }); return o; },
};
const lock = { waitLock() {}, tryLock() { return true; }, releaseLock() {} };

// ---------- Utilities ----------
const Utilities = {
  getUuid: () => crypto.randomUUID(),
  DigestAlgorithm: { SHA_256: 'sha256' },
  Charset: { UTF_8: 'utf8' },
  computeDigest: (alg, s) => Array.from(crypto.createHash(alg).update(String(s), 'utf8').digest()).map(b => (b > 127 ? b - 256 : b)),
  base64Encode: bytes => Buffer.from(bytes.map(b => (b < 0 ? b + 256 : b))).toString('base64'),
  formatDate: (d, tz, fmt) => {
    const parts = {};
    new Intl.DateTimeFormat('en-US', { timeZone: tz || 'UTC', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric', hour12: false })
      .formatToParts(d).forEach(x => { parts[x.type] = x.value; });
    const p = n => String(n).padStart(2, '0');
    const h = Number(parts.hour) % 24;
    const map = { yyyy: parts.year, yy: String(parts.year).slice(2), MM: p(parts.month), M: String(Number(parts.month)), dd: p(parts.day), d: String(Number(parts.day)), HH: p(h), mm: p(parts.minute), ss: p(parts.second) };
    return fmt.replace(/yyyy|yy|MM|M|dd|d|HH|mm|ss/g, t => map[t]);
  },
};
class TextOut {
  constructor(s) { this.content = s; this.mime = 'text/plain'; this.file = null; }
  setMimeType(m) { this.mime = m; return this; }
  downloadAsFile(f) { this.file = f; return this; }
  getContent() { return this.content; }
}
const ContentService = { createTextOutput: s => new TextOut(s), MimeType: { JSON: 'application/json', TEXT: 'text/plain' } };
class HtmlOut {
  constructor(c) { this.content = c; this.isHtml = true; }
  setTitle() { return this; } addMetaTag() { return this; } setXFrameOptionsMode() { return this; }
  getContent() { return this.content; }
}
const HtmlService = {
  createHtmlOutputFromFile: n => new HtmlOut(fs.readFileSync(path.join(SRC, n + '.html'), 'utf8')),
  XFrameOptionsMode: { ALLOWALL: 'ALLOWALL' },
};
const ScriptApp = { getService: () => ({ getUrl: () => `http://127.0.0.1:${PORT}/exec` }) };

const ctx = {
  SpreadsheetApp: { getActiveSpreadsheet: () => ss },
  PropertiesService: { getScriptProperties: () => props },
  CacheService: { getScriptCache: () => cache },
  LockService: { getScriptLock: () => lock },
  Utilities, ContentService, HtmlService, ScriptApp,
  Logger: { log: (...a) => console.log('[Logger]', ...a) },
  console, Date, JSON, Math, Object, Array, String, Number, isFinite, encodeURIComponent,
};
vm.createContext(ctx);
for (const f of ['Agen.gs', 'Code.gs']) vm.runInContext(fs.readFileSync(path.join(SRC, f), 'utf8'), ctx, { filename: f });

// ---------- HTTP ----------
const echo = {};
let echoId = 0;
function sendOut(res, out) {
  if (out instanceof HtmlOut) { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); return res.end(out.getContent()); }
  // emulate GAS: redirect to googleusercontent echo
  const id = ++echoId; echo[id] = out;
  res.writeHead(302, { Location: `http://127.0.0.1:${PORT}/echo/${id}`, 'Access-Control-Allow-Origin': '*' }); res.end();
}
const server = http.createServer((req, res) => {
  const u = url.parse(req.url, true);
  let body = '';
  req.on('data', c => (body += c));
  req.on('end', () => {
    try {
      if (u.pathname.startsWith('/echo/')) {
        const out = echo[u.pathname.split('/')[2]];
        if (!out) { res.writeHead(404); return res.end('gone'); }
        const h = { 'Content-Type': out.mime + '; charset=utf-8', 'Access-Control-Allow-Origin': '*' };
        if (out.file) h['Content-Disposition'] = `attachment; filename="${out.file}"`;
        res.writeHead(200, h); return res.end(out.getContent());
      }
      if (u.pathname === '/damage') {
        // pengujian: tiru sheet yang telanjur dirusak backend lama (kolom teks dikonversi Sheets)
        const sh = sheets.Endpoint; let n = 0;
        if (sh) sh.data.forEach((r, i) => { if (i === 0) return; [5, 7, 9].forEach(j => { delete sh.fmt[(i + 1) + ':' + (j + 1)]; const v = coerce(sh, i + 1, j + 1, r[j]); if (v !== r[j]) { r[j] = v; n++; } }); });
        Object.keys(cacheStore).filter(k => k.startsWith('ep_map')).forEach(k => delete cacheStore[k]);
        res.writeHead(200); return res.end(JSON.stringify({ damaged: n }));
      }
      if (u.pathname === '/stats') { res.writeHead(200); return res.end(JSON.stringify(Object.assign({}, stats, stats0))); }
      if (u.pathname === '/exec' && req.method === 'POST') { stats.post++; } if (u.pathname === '/exec' && req.method === 'POST') return sendOut(res, ctx.doPost({ postData: { contents: body } }));
      if (u.pathname === '/exec') return sendOut(res, ctx.doGet({ parameter: u.query }));
      if (u.pathname === '/api' && req.method === 'POST') {
        // google.script.run emulation: {fn, args}
        const { fn, args } = JSON.parse(body);
        try {
          const r = ctx[fn].apply(null, args || []);
          res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ ok: true, r }));
        } catch (e) {
          res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ ok: false, e: String(e.message || e) }));
        }
      }
      if (u.pathname === '/debug') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ props: propStore, sheets: Object.fromEntries(Object.entries(sheets).map(([k, s]) => [k, s.data])) }, null, 1));
      }
      res.writeHead(404); res.end('nf');
    } catch (e) {
      console.error(e); res.writeHead(500); res.end(String(e.stack));
    }
  });
});
server.listen(PORT, () => console.log('GAS mock on', PORT));
module.exports = { ctx };
