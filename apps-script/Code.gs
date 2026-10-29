/**
 * ============================================================
 *  ProktorLab — Panel Proktor Lab Komputer
 *  Buka / tutup Exam Browser di semua komputer secara serentak,
 *  Wake on LAN, shutdown, restart, kirim pesan, + Layar Ujian.
 *
 *  Frontend: GitHub Pages (index.html + layar.html)
 *  Backend : Google Apps Script (file ini) -> API JSON
 *  Database: Google Sheet tempat skrip ini dipasang
 *  Agen    : PowerShell di tiap komputer (lihat Agen.gs)
 *
 *  Endpoint (URL Aplikasi Web .../exec):
 *    POST {action, data, token}   -> API panel proktor
 *    POST {k, a:'checkin', ...}   -> laporan agen komputer lab
 *    GET  ?action=layar           -> data Layar Ujian (publik)
 *    GET  ?action=ping            -> cek koneksi
 *    GET  ?f=install|bat|agent|uninstall&k=KUNCI -> berkas agen
 * ============================================================
 */
var APP_VERSION = '1.0.0';

var SHEETS = {
  EP:   { name: 'Endpoint', head: ['ID', 'Nama', 'Grup', 'Keterangan', 'User Terakhir', 'IP', 'MAC', 'Broadcast', 'OS', 'Versi Agen', 'Terdaftar', 'Terakhir Online'] },
  AUTO: { name: 'Otomasi',  head: ['ID', 'Skrip', 'Aksi', 'Parameter', 'Jumlah Target', 'Jadwal', 'Batas', 'Dibuat', 'Baris Hasil', 'Status'] },
  RES:  { name: 'Hasil',    head: ['Kunci', 'ID Otomasi', 'Endpoint', 'Status', 'Keterangan', 'Diperbarui'] }
};

var ACTIONS = {
  run_exam: '#Run ExamBrowser',
  close_exam: '#Close ExamBrowser',
  wol: '#Power ON',
  shutdown: '#Shutdown',
  restart: '#Restart',
  logoff: '#Log Off',
  lock: '#Kunci Layar',
  message: '#Kirim Pesan',
  open_url: '#Buka Situs',
  update_agent: '#Perbarui Agen'
};

var NEW_GROUP = 'Endpoint Baru';

var DEFAULT_SETTINGS = {
  school: 'SMKN 1 Murung Pudak',
  tz: 'Asia/Makassar',
  interval: 10,
  examPreset: 'seb',
  examPath: 'C:\\Program Files\\SafeExamBrowser\\Application\\SafeExamBrowser.exe',
  examArgs: '',
  examProc: 'SafeExamBrowser*',
  groups: [NEW_GROUP],
  defaultGroup: NEW_GROUP
};

var DEFAULT_LAYAR = {
  label: 'TES KEMAMPUAN AKADEMIK',
  school: 'SMKN 1 Murung Pudak',
  sub: 'Harap Senang Ada Ujian \uD83D\uDE0A',
  sesi: 'SESI 1',
  token: '',
  start: 0,
  end: 0
};

/* ------------------------------------------------------------
 *  Jalankan sekali dari editor (pilih fungsi "setup" > Jalankan)
 *  untuk membuat sheet & memberi izin. Setelah itu Terapkan
 *  sebagai Aplikasi web (akses: Siapa saja) dan salin URL /exec
 *  ke panel di GitHub Pages.
 * ------------------------------------------------------------ */
function setup() {
  sheet_(SHEETS.EP); sheet_(SHEETS.AUTO); sheet_(SHEETS.RES);
  getKey_();
  if (!props_().getProperty('settings')) setJson_('settings', DEFAULT_SETTINGS);
  if (!props_().getProperty('layar')) setJson_('layar', DEFAULT_LAYAR);
  Logger.log('Siap. Sekarang klik Terapkan (Deploy) > Deployment baru > Aplikasi web.');
}

/* ======================= HTTP ======================= */

function doGet(e) {
  var p = (e && e.parameter) || {};
  if (p.f) return serveFile_(p);
  var out;
  try {
    if (p.action === 'layar') out = { ok: true, data: layarPublic_() };
    else out = { ok: true, data: { app: 'ProktorLab', version: APP_VERSION, school: settings_().school, now: Date.now() } };
  } catch (err) {
    out = { ok: false, error: errMsg_(err) };
  }
  return json_(out);
}

function doPost(e) {
  var out;
  try {
    var b = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (b && b.a === 'checkin') {
      out = b.k === getKey_() ? agentCheckin_(b) : { ok: false, error: 'Kunci agen salah' };
    } else if (b && b.action) {
      out = { ok: true, data: handleApi_(b) };
    } else {
      out = { ok: false, error: 'Permintaan tidak dikenal' };
    }
  } catch (err) {
    out = { ok: false, error: errMsg_(err) };
  }
  return json_(out);
}

function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}

function errMsg_(err) {
  return String((err && err.message) || err).replace(/^(Error|Exception):\s*/, '');
}

function serveFile_(p) {
  var key = getKey_();
  var text = function (s) { return ContentService.createTextOutput(s).setMimeType(ContentService.MimeType.TEXT); };
  if (p.k !== key) {
    return text("Write-Host 'GAGAL: kunci agen salah atau sudah diganti. Salin ulang perintah dari menu Pasang Agen di panel.' -ForegroundColor Red");
  }
  var url = ScriptApp.getService().getUrl();
  var group = str_(p.g, 60);
  if (p.f === 'agent') return text(AGENT_PS1);
  if (p.f === 'install') return text(buildInstall_(url, key, group));
  if (p.f === 'uninstall') return text(UNINSTALL_PS1);
  if (p.f === 'bat') {
    return ContentService.createTextOutput(buildBat_(url, key, group))
      .setMimeType(ContentService.MimeType.TEXT)
      .downloadAsFile('pasang-agen-proktorlab.bat');
  }
  return text("Write-Host 'Berkas tidak dikenal'");
}

function psq_(s) { return String(s || '').replace(/'/g, "''"); }

function buildInstall_(url, key, group) {
  return INSTALL_PS1
    .replace('{{URL}}', function () { return psq_(url); })
    .replace('{{KEY}}', function () { return psq_(key); })
    .replace('{{GROUP}}', function () { return psq_(group); })
    .replace('{{AGENT}}', function () { return AGENT_PS1; });
}

function installUrl_(url, key, group, f) {
  var u = url + '?f=' + (f || 'install') + '&k=' + key;
  if (group) u += '&g=' + encodeURIComponent(group).replace(/'/g, '%27');
  return u;
}

function buildBat_(url, key, group) {
  var u = installUrl_(url, key, group).replace(/%/g, '%%');
  return [
    '@echo off',
    'title Pasang Agen ProktorLab',
    'net session >nul 2>&1',
    'if %errorlevel% neq 0 (',
    '  echo Meminta hak Administrator...',
    '  powershell -NoProfile -Command "Start-Process -FilePath \'%~f0\' -Verb RunAs"',
    '  exit /b',
    ')',
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm \'' + u + '\' -UseBasicParsing | iex"',
    'echo.',
    'pause'
  ].join('\r\n');
}

/* ======================= API PANEL ======================= */

function handleApi_(req) {
  req = req || {};
  var a = String(req.action || '');
  var d = req.data || {};
  switch (a) {
    case 'status': return { hasPassword: !!props_().getProperty('admin'), version: APP_VERSION, school: settings_().school };
    case 'setup': return setupPassword_(d.password);
    case 'login': return login_(d.password);
    case 'layar': return layarPublic_();
  }
  checkSession_(req.token);
  switch (a) {
    case 'boot': return boot_();
    case 'endpoints': return { endpoints: endpointsView_(), now: Date.now() };
    case 'createJob': return createJob_(d);
    case 'jobs': return { jobs: listJobs_(), now: Date.now() };
    case 'job': return jobDetail_(d.id);
    case 'cancelJob': return cancelJob_(d.id);
    case 'clearHistory': return clearHistory_();
    case 'saveSettings': return saveSettings_(d);
    case 'saveLayar': return saveLayar_(d);
    case 'moveEndpoints': return moveEndpoints_(d.ids, d.group);
    case 'setComment': return setComment_(d.id, d.comment);
    case 'deleteEndpoints': return deleteEndpoints_(d.ids);
    case 'createGroup': return createGroup_(d.name);
    case 'renameGroup': return renameGroup_(d.from, d.to);
    case 'deleteGroup': return deleteGroup_(d.name);
    case 'regenKey': return regenKey_();
    case 'changePassword': return changePassword_(d.old, d.password);
    case 'agentCode': return { code: AGENT_PS1 };
    case 'logout': cache_().remove('sess_' + req.token); return { ok: true };
  }
  throw new Error('Aksi tidak dikenal: ' + a);
}

function boot_() {
  var s = settings_();
  var url = ScriptApp.getService().getUrl();
  var key = getKey_();
  return {
    version: APP_VERSION,
    settings: s,
    groups: groupsList_(s),
    endpoints: endpointsView_(),
    layar: layar_(),
    url: url,
    key: key,
    installUrl: installUrl_(url, key, ''),
    now: Date.now()
  };
}

/* ======================= AUTENTIKASI ======================= */

function hash_(pw, salt) {
  var raw = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, salt + '|' + pw, Utilities.Charset.UTF_8);
  return Utilities.base64Encode(raw);
}

function newSession_() {
  var t = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
  cache_().put('sess_' + t, '1', 21600);
  return { token: t };
}

function checkSession_(t) {
  if (!t || !/^[a-f0-9]{64}$/.test(String(t))) throw new Error('AUTH');
  var c = cache_();
  if (!c.get('sess_' + t)) throw new Error('AUTH');
  c.put('sess_' + t, '1', 21600);
}

function setupPassword_(pw) {
  pw = String(pw || '');
  if (props_().getProperty('admin')) throw new Error('Kata sandi admin sudah dibuat.');
  if (pw.length < 6) throw new Error('Kata sandi minimal 6 karakter.');
  var salt = Utilities.getUuid();
  setJson_('admin', { salt: salt, hash: hash_(pw, salt) });
  setup();
  return newSession_();
}

function login_(pw) {
  var c = cache_();
  var fails = Number(c.get('login_fail') || 0);
  if (fails >= 8) throw new Error('Terlalu banyak percobaan. Tunggu 5 menit.');
  var adm = getJson_('admin', null);
  if (!adm) throw new Error('Kata sandi admin belum dibuat.');
  if (hash_(String(pw || ''), adm.salt) !== adm.hash) {
    c.put('login_fail', String(fails + 1), 300);
    throw new Error('Kata sandi salah.');
  }
  return newSession_();
}

function changePassword_(oldPw, pw) {
  var adm = getJson_('admin', null);
  if (!adm || hash_(String(oldPw || ''), adm.salt) !== adm.hash) throw new Error('Kata sandi lama salah.');
  pw = String(pw || '');
  if (pw.length < 6) throw new Error('Kata sandi baru minimal 6 karakter.');
  var salt = Utilities.getUuid();
  setJson_('admin', { salt: salt, hash: hash_(pw, salt) });
  return { ok: true };
}

/* ======================= AGEN ======================= */

function agentCheckin_(b) {
  var id = normId_(b.id);
  if (!id) return { ok: false, error: 'ID komputer kosong' };
  var now = Date.now();
  var s = settings_();
  var c = cache_();
  c.put('hb_' + id, JSON.stringify({ t: now, user: str_(b.user, 120), exam: !!b.exam }), 21600);
  var ep = ensureEndpoint_(id, b, s);

  // catat "terakhir online" ke sheet maksimal tiap 5 menit
  if (ep && !c.get('sw_' + id)) {
    try {
      var sh = sheet_(SHEETS.EP);
      if (String(sh.getRange(ep.row, 1).getValue()) === id) sh.getRange(ep.row, 12).setValue(new Date());
      c.put('sw_' + id, '1', 300);
    } catch (err) {}
  }

  var results = [].concat(b.results || []).filter(function (x) { return x && x.id; });
  var acks = [].concat(b.acks || []).filter(Boolean);
  var q = qGet_(id);
  var expired = q.some(function (j) { return j.dl < now; });
  if (results.length || acks.length || expired) q = applyAgentUpdates_(id, results, acks, now);

  return {
    ok: true,
    now: Date.now(),
    interval: s.interval,
    cfg: { examPath: s.examPath, examArgs: s.examArgs, examProc: s.examProc },
    jobs: q.filter(function (j) { return j.dl >= now; }).map(function (j) {
      return { id: j.id, a: j.a, p: j.p || {}, at: j.at, dl: j.dl };
    })
  };
}

function ensureEndpoint_(id, b, s) {
  var info = {
    user: str_(b.user, 120), ip: str_(b.ip, 40), mac: str_(b.mac, 24),
    bc: str_(b.bc, 40), os: str_(b.os, 80), ver: str_(b.ver, 20)
  };
  var map = epMap_();
  var ep = map[id];
  var changed = ep && (
    (info.user && info.user !== ep.user) || (info.ip && info.ip !== ep.ip) || (info.mac && info.mac !== ep.mac) ||
    (info.bc && info.bc !== ep.bc) || (info.os && info.os !== ep.os) || (info.ver && info.ver !== ep.ver));
  if (ep && !changed) return ep;

  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    epInvalidate_();
    map = epMap_();
    ep = map[id];
    var sh = sheet_(SHEETS.EP);
    if (!ep) {
      var group = str_(b.grp, 60) || s.defaultGroup || NEW_GROUP;
      sh.appendRow([id, id, group, '', info.user, info.ip, info.mac, info.bc, info.os, info.ver, new Date(), new Date()]);
      var s2 = settings_();
      if (s2.groups.indexOf(group) < 0) { s2.groups.push(group); setJson_('settings', s2); }
    } else {
      sh.getRange(ep.row, 5, 1, 6).setValues([[
        info.user || ep.user, info.ip || ep.ip, info.mac || ep.mac, info.bc || ep.bc, info.os || ep.os, info.ver || ep.ver
      ]]);
    }
    epInvalidate_();
    return epMap_()[id];
  } finally {
    lock.releaseLock();
  }
}

function applyAgentUpdates_(id, results, acks, now) {
  var resMap = {};
  results.forEach(function (r) { resMap[String(r.id)] = r; });
  var ackSet = {};
  acks.forEach(function (a) { ackSet[String(a)] = 1; });
  var writes = [];
  var keep = [];
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    qGet_(id).forEach(function (j) {
      var r = resMap[j.id];
      if (r) {
        var ok = r.s === 'ok';
        writes.push({ j: j, status: ok ? 'Berhasil' : 'Gagal', msg: str_(r.o, 900) || (ok ? 'Selesai.' : 'Gagal.'), notIf: j.wol ? ['Berhasil'] : null });
        return;
      }
      if (j.dl < now) {
        writes.push({ j: j, status: 'Kedaluwarsa', msg: 'Endpoint tidak online sebelum batas waktu.', onlyIf: ['Menunggu', 'Diterima'] });
        return;
      }
      if (ackSet[j.id] && !j.ack) {
        j.ack = 1;
        writes.push({ j: j, status: 'Diterima', msg: j.at > now + 3000 ? 'Diterima, menunggu waktu jadwal.' : 'Sedang dijalankan...', onlyIf: ['Menunggu'] });
      }
      keep.push(j);
    });
    qSet_(id, keep);
  } finally {
    lock.releaseLock();
  }
  if (writes.length) {
    var sh = sheet_(SHEETS.RES);
    writes.forEach(function (w) { writeRows_(sh, w.j, w.status, w.msg, w.onlyIf, w.notIf); });
  }
  return keep;
}

/** Perbarui baris Hasil milik sebuah item antrean. */
function writeRows_(sh, j, status, msg, onlyIf, notIf) {
  var targets = j.t || [];
  if (!targets.length) return;
  var keys = {};
  targets.forEach(function (t) { keys[j.id + '|' + t] = 1; });
  var found = 0;
  var block = [];
  try { if (j.r0 > 1) block = sh.getRange(j.r0, 1, targets.length, 6).getValues(); } catch (e) { block = []; }
  var changed = false;
  var stamp = new Date();
  block.forEach(function (v) {
    if (!keys[String(v[0])]) return;
    found++;
    delete keys[String(v[0])];
    var cur = String(v[3]);
    if (onlyIf && onlyIf.indexOf(cur) < 0) return;
    if (notIf && notIf.indexOf(cur) >= 0) return;
    v[3] = status; v[4] = msg; v[5] = stamp; changed = true;
  });
  if (changed) sh.getRange(j.r0, 4, block.length, 3).setValues(block.map(function (v) { return [v[3], v[4], v[5]]; }));
  if (found < targets.length) {
    // baris bergeser (misal sheet diedit manual) -> cari satu per satu
    Object.keys(keys).forEach(function (k) {
      var f = sh.getRange('A:A').createTextFinder(k).matchEntireCell(true).findNext();
      if (!f) return;
      var row = f.getRow();
      var cur = String(sh.getRange(row, 4).getValue());
      if (onlyIf && onlyIf.indexOf(cur) < 0) return;
      if (notIf && notIf.indexOf(cur) >= 0) return;
      sh.getRange(row, 4, 1, 3).setValues([[status, msg, stamp]]);
    });
  }
}

/* ======================= OTOMASI ======================= */

function createJob_(d) {
  var a = String(d.action || '');
  if (!ACTIONS[a]) throw new Error('Skrip tidak dikenal.');
  var params = {};
  if (a === 'message') {
    params.text = str_(d.params && d.params.text, 500).trim();
    if (!params.text) throw new Error('Isi pesan wajib diisi.');
  }
  if (a === 'open_url') {
    params.url = str_(d.params && d.params.url, 500).trim();
    if (!/^https?:\/\//i.test(params.url)) throw new Error('URL harus diawali http:// atau https://');
  }
  var map = epMap_();
  var seen = {};
  var targets = [].concat(d.targets || []).map(normId_).filter(function (t) {
    if (!t || !map[t] || seen[t]) return false;
    seen[t] = 1; return true;
  });
  if (!targets.length) throw new Error('Pilih minimal satu endpoint.');

  var now = Date.now();
  var at = Number(d.runAt) > 0 ? Number(d.runAt) : now;
  if (at < now - 120000) throw new Error('Waktu jadwal sudah lewat.');
  var winMin = Math.min(Math.max(Number(d.windowMin) || 60, 1), 7 * 24 * 60);
  var dl = Math.max(at, now) + winMin * 60000;
  var id = 'J' + Utilities.formatDate(new Date(), settings_().tz || 'Asia/Jakarta', 'yyMMddHHmmss') + Math.floor(Math.random() * 900 + 100);

  var rows = targets.map(function (t) {
    return [id + '|' + t, id, t, 'Menunggu', at > now + 5000 ? 'Dijadwalkan.' : 'Menunggu endpoint melapor...', new Date()];
  });

  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var shR = sheet_(SHEETS.RES);
    var start = shR.getLastRow() + 1;
    if (a === 'wol') {
      var s = settings_();
      var ids = Object.keys(map);
      var hbs = heartbeats_(ids);
      var win = onlineWindow_(s);
      var tg = {};
      targets.forEach(function (t) { tg[map[t].group] = 1; });
      var relays = ids.filter(function (x) {
        return hbs[x] && now - hbs[x].t < win && targets.indexOf(x) < 0;
      }).sort(function (x, y) {
        return (tg[map[y].group] ? 1 : 0) - (tg[map[x].group] ? 1 : 0);
      }).slice(0, 3);
      var macs = targets.map(function (t) { return { m: map[t].mac, b: map[t].bc }; }).filter(function (x) { return x.m; });
      if (!relays.length || !macs.length) {
        rows.forEach(function (r) {
          r[3] = 'Gagal';
          r[4] = !relays.length
            ? 'Tidak ada komputer lain yang online untuk mengirim sinyal Wake on LAN. Nyalakan PC proktor yang sudah terpasang agen.'
            : 'Alamat MAC belum diketahui (agen belum pernah melapor).';
        });
      } else {
        rows.forEach(function (r) { r[4] = 'Menunggu dikirim lewat ' + relays.join(', ') + '...'; });
        relays.forEach(function (rid) {
          var q = qGet_(rid);
          q.push({ id: id, a: a, p: { macs: macs }, at: at, dl: dl, r0: start, t: targets, wol: 1 });
          qSet_(rid, q);
        });
      }
    } else {
      targets.forEach(function (t, i) {
        var q = qGet_(t);
        q.push({ id: id, a: a, p: params, at: at, dl: dl, r0: start + i, t: [t] });
        qSet_(t, q);
      });
    }
    shR.getRange(start, 1, rows.length, 6).setValues(rows);
    sheet_(SHEETS.AUTO).appendRow([id, ACTIONS[a], a, JSON.stringify(params), targets.length, new Date(at), new Date(dl), new Date(), start, 'Aktif']);
  } finally {
    lock.releaseLock();
  }
  return { id: id };
}

function listJobs_() {
  var sh = sheet_(SHEETS.AUTO);
  var n = sh.getLastRow();
  if (n < 2) return [];
  var take = Math.min(n - 1, 60);
  var rows = sh.getRange(n - take + 1, 1, take, 10).getValues();
  var minStart = Infinity;
  rows.forEach(function (r) { var v = Number(r[8]); if (v > 1 && v < minStart) minStart = v; });
  var counts = {};
  var shR = sheet_(SHEETS.RES);
  var m = shR.getLastRow();
  if (isFinite(minStart) && m >= minStart) {
    shR.getRange(minStart, 2, m - minStart + 1, 3).getValues().forEach(function (v) {
      var c = counts[v[0]] = counts[v[0]] || {};
      c[v[2]] = (c[v[2]] || 0) + 1;
    });
  }
  return rows.reverse().map(function (r) { return jobObj_(r, counts[r[0]] || {}); });
}

function jobObj_(r, counts) {
  var p = {};
  try { p = JSON.parse(r[3] || '{}'); } catch (e) {}
  return {
    id: String(r[0]), script: String(r[1]), action: String(r[2]), params: p,
    total: Number(r[4]) || 0, at: ms_(r[5]), dl: ms_(r[6]), created: ms_(r[7]),
    status: String(r[9] || ''), counts: counts || {}
  };
}

function findAutoRow_(id) {
  var sh = sheet_(SHEETS.AUTO);
  var f = sh.getRange('A:A').createTextFinder(String(id)).matchEntireCell(true).findNext();
  if (!f) throw new Error('Otomasi tidak ditemukan.');
  return { sh: sh, row: f.getRow(), values: sh.getRange(f.getRow(), 1, 1, 10).getValues()[0] };
}

function jobRows_(id, start, total) {
  var shR = sheet_(SHEETS.RES);
  var out = [];
  if (start > 1 && total > 0 && shR.getLastRow() >= start) {
    var cnt = Math.min(total, shR.getLastRow() - start + 1);
    shR.getRange(start, 1, cnt, 6).getValues().forEach(function (v, i) {
      if (String(v[1]) === id) out.push({ row: start + i, v: v });
    });
  }
  if (out.length < total) {
    out = [];
    shR.getRange('B:B').createTextFinder(id).matchEntireCell(true).findAll().forEach(function (rg) {
      out.push({ row: rg.getRow(), v: shR.getRange(rg.getRow(), 1, 1, 6).getValues()[0] });
    });
  }
  return out;
}

function jobDetail_(id) {
  id = String(id || '');
  var a = findAutoRow_(id);
  var rows = jobRows_(id, Number(a.values[8]), Number(a.values[4]));
  var map = epMap_();
  var hbs = heartbeats_(Object.keys(map));
  var win = onlineWindow_(settings_());
  var now = Date.now();
  var counts = {};
  var list = rows.map(function (x) {
    var v = x.v, ep = String(v[2]);
    counts[v[3]] = (counts[v[3]] || 0) + 1;
    return {
      ep: ep, status: String(v[3]), msg: String(v[4]), t: ms_(v[5]),
      group: map[ep] ? map[ep].group : '-',
      online: !!(hbs[ep] && now - hbs[ep].t < win)
    };
  });
  return { job: jobObj_(a.values, counts), rows: list, now: now };
}

function cancelJob_(id) {
  id = String(id || '');
  var a = findAutoRow_(id);
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    props_().getKeys().forEach(function (k) {
      if (k.indexOf('q_') !== 0) return;
      var epId = k.slice(2);
      var q = getJson_(k, []);
      var f = q.filter(function (j) { return j.id !== id; });
      if (f.length !== q.length) qSet_(epId, f);
    });
    var shR = sheet_(SHEETS.RES);
    var stamp = new Date();
    jobRows_(id, Number(a.values[8]), Number(a.values[4])).forEach(function (x) {
      var cur = String(x.v[3]);
      if (cur === 'Menunggu' || cur === 'Diterima') shR.getRange(x.row, 4, 1, 3).setValues([['Dibatalkan', 'Dibatalkan oleh proktor.', stamp]]);
    });
    a.sh.getRange(a.row, 10).setValue('Dibatalkan');
  } finally {
    lock.releaseLock();
  }
  return { ok: true };
}

function clearHistory_() {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    [SHEETS.AUTO, SHEETS.RES].forEach(function (def) {
      var sh = sheet_(def);
      if (sh.getLastRow() > 1) sh.deleteRows(2, sh.getLastRow() - 1);
    });
    var p = props_();
    var ids = {};
    Object.keys(epMap_()).forEach(function (id) { ids[id] = 1; });
    p.getKeys().forEach(function (k) { if (k.indexOf('q_') === 0) { ids[k.slice(2)] = 1; p.deleteProperty(k); } });
    var keys = Object.keys(ids).map(function (id) { return 'qc_' + id; });
    for (var i = 0; i < keys.length; i += 100) cache_().removeAll(keys.slice(i, i + 100));
  } finally {
    lock.releaseLock();
  }
  return { ok: true };
}

/* ======================= ENDPOINT & GRUP ======================= */

function endpointsView_() {
  var map = epMap_();
  var ids = Object.keys(map);
  var hbs = heartbeats_(ids);
  var win = onlineWindow_(settings_());
  var now = Date.now();
  return ids.map(function (id) {
    var e = map[id], h = hbs[id];
    var online = !!(h && now - h.t < win);
    return {
      id: id, name: e.name, group: e.group, comment: e.comment,
      user: online ? (h.user || '') : e.user, loggedIn: online && !!h.user,
      ip: e.ip, mac: e.mac, os: e.os, ver: e.ver,
      online: online, exam: online && !!h.exam,
      seen: h ? h.t : e.seen, reg: e.reg
    };
  });
}

function groupsList_(s) {
  var set = {};
  (s.groups || []).forEach(function (g) { set[g] = 1; });
  set[NEW_GROUP] = 1;
  var map = epMap_();
  Object.keys(map).forEach(function (id) { set[map[id].group] = 1; });
  return Object.keys(set).sort(function (a, b) {
    if (a === NEW_GROUP) return -1;
    if (b === NEW_GROUP) return 1;
    return a.localeCompare(b);
  });
}

function withEpSheet_(fn) {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var sh = sheet_(SHEETS.EP);
    var n = sh.getLastRow();
    var values = n > 1 ? sh.getRange(2, 1, n - 1, SHEETS.EP.head.length).getValues() : [];
    var res = fn(sh, values);
    epInvalidate_();
    return res;
  } finally {
    lock.releaseLock();
  }
}

function moveEndpoints_(ids, group) {
  group = str_(group, 60).trim();
  if (!group) throw new Error('Nama grup kosong.');
  var set = {};
  [].concat(ids || []).forEach(function (i) { set[normId_(i)] = 1; });
  withEpSheet_(function (sh, values) {
    if (!values.length) return;
    var col = values.map(function (r) { return [set[String(r[0])] ? group : r[2]]; });
    sh.getRange(2, 3, col.length, 1).setValues(col);
  });
  var s = settings_();
  if (s.groups.indexOf(group) < 0) { s.groups.push(group); setJson_('settings', s); }
  return { ok: true };
}

function setComment_(id, comment) {
  id = normId_(id);
  withEpSheet_(function (sh, values) {
    for (var i = 0; i < values.length; i++) {
      if (String(values[i][0]) === id) { sh.getRange(i + 2, 4).setValue(str_(comment, 120)); return; }
    }
  });
  return { ok: true };
}

function deleteEndpoints_(ids) {
  var set = {};
  [].concat(ids || []).forEach(function (i) { set[normId_(i)] = 1; });
  withEpSheet_(function (sh, values) {
    for (var i = values.length - 1; i >= 0; i--) {
      if (set[String(values[i][0])]) sh.deleteRow(i + 2);
    }
  });
  var p = props_();
  Object.keys(set).forEach(function (id) { p.deleteProperty('q_' + id); cache_().removeAll(['hb_' + id, 'qc_' + id]); });
  return { ok: true };
}

function createGroup_(name) {
  name = str_(name, 60).trim();
  if (!name) throw new Error('Nama grup kosong.');
  var s = settings_();
  if (s.groups.indexOf(name) < 0) { s.groups.push(name); setJson_('settings', s); }
  return { groups: groupsList_(s) };
}

function renameGroup_(from, to) {
  from = String(from || ''); to = str_(to, 60).trim();
  if (!to) throw new Error('Nama grup baru kosong.');
  if (from === NEW_GROUP) throw new Error('Grup "' + NEW_GROUP + '" tidak bisa diganti namanya.');
  withEpSheet_(function (sh, values) {
    if (!values.length) return;
    sh.getRange(2, 3, values.length, 1).setValues(values.map(function (r) { return [String(r[2]) === from ? to : r[2]]; }));
  });
  var s = settings_();
  s.groups = s.groups.map(function (g) { return g === from ? to : g; });
  if (s.groups.indexOf(to) < 0) s.groups.push(to);
  if (s.defaultGroup === from) s.defaultGroup = to;
  setJson_('settings', s);
  return { groups: groupsList_(s) };
}

function deleteGroup_(name) {
  name = String(name || '');
  if (name === NEW_GROUP) throw new Error('Grup "' + NEW_GROUP + '" tidak bisa dihapus.');
  withEpSheet_(function (sh, values) {
    if (!values.length) return;
    sh.getRange(2, 3, values.length, 1).setValues(values.map(function (r) { return [String(r[2]) === name ? NEW_GROUP : r[2]]; }));
  });
  var s = settings_();
  s.groups = s.groups.filter(function (g) { return g !== name; });
  if (s.defaultGroup === name) s.defaultGroup = NEW_GROUP;
  setJson_('settings', s);
  return { groups: groupsList_(s) };
}

/* ======================= PENGATURAN & LAYAR ======================= */

function saveSettings_(d) {
  var s = settings_();
  if (d.school != null) s.school = str_(d.school, 80);
  if (d.tz && ['Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura'].indexOf(d.tz) >= 0) s.tz = d.tz;
  if (d.interval != null) s.interval = Math.min(120, Math.max(5, Math.round(Number(d.interval) || 10)));
  if (d.examPreset != null) s.examPreset = str_(d.examPreset, 20);
  if (d.examPath != null) s.examPath = str_(d.examPath, 260).trim();
  if (d.examArgs != null) s.examArgs = str_(d.examArgs, 500).trim();
  if (d.examProc != null) s.examProc = str_(d.examProc, 120).trim();
  if (d.defaultGroup != null && str_(d.defaultGroup, 60).trim()) s.defaultGroup = str_(d.defaultGroup, 60).trim();
  setJson_('settings', s);
  return { settings: s };
}

function layar_() {
  return Object.assign({}, DEFAULT_LAYAR, cfg_().layar || {});
}

function saveLayar_(d) {
  var l = layar_();
  ['label', 'school', 'sub', 'sesi', 'token'].forEach(function (k) {
    if (d[k] != null) l[k] = str_(d[k], 120);
  });
  if (d.start != null) l.start = Number(d.start) || 0;
  if (d.end != null) l.end = Number(d.end) || 0;
  setJson_('layar', l);
  return { layar: l };
}

function layarPublic_() {
  var s = settings_();
  return { layar: layar_(), tz: s.tz, now: Date.now() };
}

function regenKey_() {
  var k = newKey_();
  props_().setProperty('agentKey', k);
  cache_().remove('cfg');
  var url = ScriptApp.getService().getUrl();
  return { key: k, installUrl: installUrl_(url, k, '') };
}

/* ======================= UTILITAS ======================= */

function ss_() { return SpreadsheetApp.getActiveSpreadsheet(); }
function props_() { return PropertiesService.getScriptProperties(); }
function cache_() { return CacheService.getScriptCache(); }

function sheet_(def) {
  var ss = ss_();
  var sh = ss.getSheetByName(def.name);
  if (!sh) {
    sh = ss.insertSheet(def.name);
    sh.getRange(1, 1, 1, def.head.length).setValues([def.head])
      .setFontWeight('bold').setBackground('#1b2b8f').setFontColor('#ffffff');
    sh.setFrozenRows(1);
  }
  return sh;
}

function getJson_(key, def) {
  var v = props_().getProperty(key);
  if (!v) return def;
  try { return JSON.parse(v); } catch (e) { return def; }
}

function setJson_(key, val) {
  props_().setProperty(key, JSON.stringify(val));
  if (key === 'settings' || key === 'layar') cache_().remove('cfg');
}

/*
 * Kuota Properties akun Gmail biasa ±50.000 baca/tulis per hari, padahal
 * puluhan agen melapor tiap beberapa detik. Karena itu pengaturan, kunci,
 * isi layar dan antrean perintah dibaca dari CacheService; Properties hanya
 * dibaca saat cache kosong dan ditulis saat ada perubahan.
 */
function cfg_() {
  var c = cache_().get('cfg');
  if (c) { try { return JSON.parse(c); } catch (e) {} }
  var p = props_();
  var k = p.getProperty('agentKey');
  if (!k) { k = newKey_(); p.setProperty('agentKey', k); }
  var obj = { key: k, settings: getJson_('settings', {}), layar: getJson_('layar', {}) };
  try { cache_().put('cfg', JSON.stringify(obj), 900); } catch (e) {}
  return obj;
}

function newKey_() { return Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '').slice(0, 8); }

function settings_() {
  var s = Object.assign({}, DEFAULT_SETTINGS, cfg_().settings || {});
  if (!Array.isArray(s.groups)) s.groups = [NEW_GROUP];
  return s;
}

function getKey_() { return cfg_().key; }

function qGet_(id) {
  var c = cache_().get('qc_' + id);
  if (c != null) { try { return JSON.parse(c); } catch (e) {} }
  var q = getJson_('q_' + id, []);
  try { cache_().put('qc_' + id, JSON.stringify(q), 21600); } catch (e) {}
  return q;
}

function qSet_(id, q) {
  q = q.slice(-25);
  while (q.length > 1 && JSON.stringify(q).length > 8500) q.shift();
  if (q.length) setJson_('q_' + id, q);
  else props_().deleteProperty('q_' + id);
  try { cache_().put('qc_' + id, JSON.stringify(q), 21600); } catch (e) {}
}

function epMap_() {
  var c = cache_().get('ep_map');
  if (c) { try { return JSON.parse(c); } catch (e) {} }
  var sh = sheet_(SHEETS.EP);
  var n = sh.getLastRow();
  var map = {};
  if (n > 1) {
    sh.getRange(2, 1, n - 1, SHEETS.EP.head.length).getValues().forEach(function (r, i) {
      if (!r[0]) return;
      map[String(r[0])] = {
        row: i + 2, id: String(r[0]), name: String(r[1] || r[0]), group: String(r[2] || NEW_GROUP),
        comment: String(r[3] || ''), user: String(r[4] || ''), ip: String(r[5] || ''), mac: String(r[6] || ''),
        bc: String(r[7] || ''), os: String(r[8] || ''), ver: String(r[9] || ''), reg: ms_(r[10]), seen: ms_(r[11])
      };
    });
  }
  try { cache_().put('ep_map', JSON.stringify(map), 600); } catch (e) {}
  return map;
}

function epInvalidate_() { cache_().remove('ep_map'); }

function heartbeats_(ids) {
  var out = {};
  if (!ids.length) return out;
  var keys = ids.map(function (i) { return 'hb_' + i; });
  var got = {};
  for (var i = 0; i < keys.length; i += 100) {
    var part = cache_().getAll(keys.slice(i, i + 100));
    Object.keys(part).forEach(function (k) { got[k] = part[k]; });
  }
  ids.forEach(function (id) {
    var v = got['hb_' + id];
    if (v) { try { out[id] = JSON.parse(v); } catch (e) {} }
  });
  return out;
}

function onlineWindow_(s) { return Math.max(30, (Number(s.interval) || 10) * 3 + 10) * 1000; }

function normId_(x) {
  return String(x == null ? '' : x).trim().toUpperCase().replace(/[^A-Z0-9._\- ]/g, '').slice(0, 40);
}

function str_(v, max) { return String(v == null ? '' : v).slice(0, max || 200); }

function ms_(v) {
  if (v instanceof Date) return v.getTime();
  var n = Number(v);
  return isFinite(n) ? n : 0;
}
