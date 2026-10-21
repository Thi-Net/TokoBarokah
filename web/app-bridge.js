// ============================================
// KelontongPOS Bridge — Supabase Edition
// - Semua panggilan lewat Supabase PostgREST RPC (/rest/v1/rpc/<fn>)
// - OFFLINE: operasi tulis masuk antrean localStorage, otomatis flush saat online
// - OFFLINE: operasi baca pakai cache terakhir
// - Nama fungsi backend (Postgres): snake_case, ada peta konversi argumen
// ============================================

const SB_URL_KEY = 'kpos_sb_url';
const SB_KEY_STORE = 'kpos_sb_key';
const QUEUE_KEY = 'kpos_sync_queue';
const CACHE_PREFIX = 'kpos_cache_';

// Peta: nama fungsi gaya lama (dipakai UI) -> { rpc, args: [nama param postgres per posisi] }
const FN_MAP = {
  getDashboardSummary:          { rpc: 'get_dashboard_summary', args: [] },
  getActiveProductsList:        { rpc: 'get_active_products_list', args: [] },
  getStockLedgerData:           { rpc: 'get_stock_ledger_data', args: [] },
  getDailyOmzetData:            { rpc: 'get_daily_omzet_data', args: ['p_date'] },
  getFilteredFinancialReport:   { rpc: 'get_filtered_financial_report', args: ['p_period', 'p_date'] },
  checkProductExists:           { rpc: 'check_product_exists', args: ['p_name', 'p_unit'] },
  getRawSheetData:              { rpc: 'get_raw_table', args: ['p_table'] },
  updateSellingPrice:           { rpc: 'update_selling_price', args: ['p_product_id', 'p_unit_name', 'p_new_price'] },
  processMultiSale:             { rpc: 'process_multi_sale', args: ['p_items'] },
};

// Fungsi tulis yang payload-nya objek dari UI -> konversi ke param postgres
const ADAPTERS = {
  processPurchase(p) {
    return ['process_purchase', { p_supplier: p.supplier, p_invoice: p.invoice, p_product_id: p.productId,
      p_unit_name: p.unitName, p_qty: p.qty, p_total_price: p.totalPrice, p_notes: p.notes || 'Manual' }];
  },
  processStockOpname(p) {
    const c = (p.physicalCounts && p.physicalCounts[0]) || {};
    return ['process_stock_opname', { p_product_id: p.productId, p_unit_name: c.unitName,
      p_qty: c.qty, p_notes: p.notes || '' }];
  },
  processExpense(p) {
    return ['process_expense', { p_category: p.category, p_description: p.description,
      p_amount: p.amount, p_payment_method: p.paymentMethod, p_notes: p.notes || '' }];
  },
  addNewProduct(p) {
    return ['add_new_product', { p_name: p.name, p_category: p.category, p_base_unit: p.baseUnit,
      p_hpp: p.hpp, p_selling_price: p.sellingPrice }];
  },
  addNewUnitToProduct(p) {
    return ['add_new_unit_to_product', { p_product_id: p.productId, p_unit_name: p.unitName,
      p_conversion: p.conversionRate, p_selling_price: p.sellingPrice }];
  },
};

const WRITE_FNS = ['processMultiSale', 'processPurchase', 'processStockOpname', 'processExpense',
  'addNewProduct', 'addNewUnitToProduct', 'updateSellingPrice', 'saveRawSheetData'];

const Bridge = {
  get url() { return (localStorage.getItem(SB_URL_KEY) || '').trim().replace(/\/$/, ''); },
  get key() { return (localStorage.getItem(SB_KEY_STORE) || '').trim(); },
  queue: JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]'),

  setConfig(u, k) {
    localStorage.setItem(SB_URL_KEY, (u || '').trim().replace(/\/$/, ''));
    localStorage.setItem(SB_KEY_STORE, (k || '').trim());
  },

  saveQueue() { localStorage.setItem(QUEUE_KEY, JSON.stringify(this.queue)); },

  cacheSet(fn, key, data) {
    try { localStorage.setItem(CACHE_PREFIX + fn + '_' + (key || ''), JSON.stringify({ t: Date.now(), data })); } catch (e) {}
  },
  cacheGet(fn, key) {
    try {
      const raw = localStorage.getItem(CACHE_PREFIX + fn + '_' + (key || ''));
      return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
  },

  headers() {
    return { 'apikey': this.key, 'Authorization': 'Bearer ' + this.key, 'Content-Type': 'application/json' };
  },

  // Konversi (fn, args gaya lama) -> (rpc, params postgres)
  mapCall(fn, args) {
    if (ADAPTERS[fn]) {
      const [rpc, params] = ADAPTERS[fn](args[0] || {});
      return [rpc, params];
    }
    const m = FN_MAP[fn];
    if (!m) return [fn, {}];
    const params = {};
    (m.args || []).forEach((name, i) => { params[name] = args[i]; });
    return [m.rpc, params];
  },

  // Database Raw: get_raw_table -> bentuk matrix [header, ...rows] ala sheet
  shapeRawTable(data) {
    if (!data || !data.columns) return data;
    const cols = data.columns;
    return [cols].concat((data.rows || []).map(r => cols.map(c => {
      const v = r[c];
      return (v === null || v === undefined) ? '' : v;
    })));
  },

  async call(fn, args) {
    const [rpc, params] = this.mapCall(fn, args);
    const res = await fetch(this.url + '/rest/v1/rpc/' + rpc, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(params || {})
    });
    if (!res.ok) {
      let msg = 'HTTP ' + res.status;
      try { const j = await res.json(); msg = j.message || msg; } catch (e) {}
      throw new Error(msg);
    }
    const json = await res.json();
    if (fn === 'getRawSheetData') return this.shapeRawTable(json);
    return json;
  },

  // Database Raw "Simpan": upsert products / product_units (dua tabel yang boleh diedit)
  async saveRawTable(sheetName, matrix) {
    if (!this.url || !this.key) throw new Error('Supabase belum diatur');
    const headers = this.headers();
    headers['Prefer'] = 'resolution=merge-duplicates';
    const cols = (matrix[0] || []).map(c => String(c).trim().toLowerCase());
    const rows = matrix.slice(1)
      .filter(r => r.some(c => String(c).trim() !== ''))
      .map(r => {
        const o = {};
        cols.forEach((c, i) => {
          let v = r[i] !== undefined ? r[i] : '';
          const s = String(v).trim();
          if (/^(true|false)$/i.test(s)) v = s.toLowerCase() === 'true';
          else if (s !== '' && !isNaN(s) && /^(reorder_point|conversion_rate|price|amount|total_|qty|balance|hpp)/.test(c)) v = Number(s);
          o[c] = v;
        });
        return o;
      });
    if (rows.length === 0) return { status: 'success' };
    let table, conflict;
    if (sheetName === 'PRODUCTS') { table = 'products'; conflict = 'id'; }
    else if (sheetName === 'PRODUCT_UNITS') { table = 'product_units'; conflict = 'product_id,unit_name'; }
    else throw new Error('Simpan langsung hanya untuk tabel PRODUCTS / PRODUCT_UNITS');
    const res = await fetch(this.url + '/rest/v1/' + table + '?on_conflict=' + conflict, {
      method: 'POST', headers: headers, body: JSON.stringify(rows)
    });
    if (!res.ok) {
      let msg = 'HTTP ' + res.status;
      try { msg = (await res.json()).message || msg; } catch (e) {}
      throw new Error(msg);
    }
    return { status: 'success' };
  },

  async flushQueue() {
    if (!this.url || !this.key || !navigator.onLine) return 0;
    let sent = 0;
    while (this.queue.length > 0) {
      const job = this.queue[0];
      try {
        if (job.fn === 'saveRawSheetData') await this.saveRawTable(job.args[0], job.args[1]);
        else await this.call(job.fn, job.args);
        this.queue.shift(); this.saveQueue(); sent++;
      } catch (e) {
        if (String(e.message).includes('Failed to fetch')) break; // offline lagi
        this.queue.shift(); this.saveQueue();
        if (window.showToast) showToast('Gagal sinkron: ' + e.message, 'warning');
        sent++;
      }
    }
    if (sent > 0 && window.showToast) showToast(sent + ' data tersinkron ke Supabase', 'success');
    return sent;
  },
};

// ==== Shim google.script.run ====
// Mendukung: google.script.run.fnName(args)
//        dan google.script.run.withSuccessHandler(cb)[.withFailureHandler(cb2)].fnName(args)
function makeRunner(fn) {
  const state = { success: null, failure: null, fn: fn };

  const runner = function(...args) {
    const fnName = state.fn;
    (async () => {
      try {
        if (!fnName) throw new Error('Nama fungsi backend belum ditentukan');
        if (WRITE_FNS.includes(fnName)) {
          if (!Bridge.url || !Bridge.key || !navigator.onLine) {
            Bridge.queue.push({ fn: fnName, args, t: Date.now() });
            Bridge.saveQueue();
            state.success && state.success({ status: 'queued_offline', message: 'Disimpan offline. Akan tersinkron saat online.' });
            return;
          }
          const r = (fnName === 'saveRawSheetData')
            ? await Bridge.saveRawTable(args[0], args[1])
            : await Bridge.call(fnName, args);
          state.success && state.success(r);
          Bridge.flushQueue();
        } else {
          if (!Bridge.url || !Bridge.key) {
            const c = Bridge.cacheGet(fnName, JSON.stringify(args));
            if (c) state.success && state.success(c.data);
            else if (state.failure) state.failure(new Error('Supabase belum diatur — buka menu Sinkron & URL.'));
            return;
          }
          try {
            const r = await Bridge.call(fnName, args);
            Bridge.cacheSet(fnName, JSON.stringify(args), r);
            state.success && state.success(r);
          } catch (e) {
            const c = Bridge.cacheGet(fnName, JSON.stringify(args));
            if (c) state.success && state.success(c.data);
            else if (state.failure) state.failure(e);
          }
        }
      } catch (e) {
        if (String(e.message).includes('Failed to fetch') && WRITE_FNS.includes(fnName)) {
          Bridge.queue.push({ fn: fnName, args, t: Date.now() });
          Bridge.saveQueue();
          state.success && state.success({ status: 'queued_offline', message: 'Disimpan offline. Akan tersinkron saat online.' });
        } else if (state.failure) state.failure(e);
      }
    })();
  };

  runner.withSuccessHandler = function(cb) { state.success = cb; return proxied; };
  runner.withFailureHandler = function(cb) { state.failure = cb; return proxied; };

  // Proxy agar akses properti (mis. runner.getDashboardSummary) mengubah nama fungsi tujuan
  const proxied = new Proxy(runner, {
    get(t, p) {
      if (p === 'withSuccessHandler' || p === 'withFailureHandler') return t[p];
      if (typeof p === 'string' && p !== 'then' && p !== 'call' && !(p in t)) {
        state.fn = p;
        return t;
      }
      return t[p];
    }
  });
  return proxied;
}

window.google = window.google || {};
google.script = google.script || {};
google.script.run = makeRunner(null);

// ==== Status koneksi & pengaturan (dipakai oleh index.html) ====
async function ensureSupabase() {
  const u = Bridge.url, k = Bridge.key;
  if (typeof window.setConnStatus === 'function') {
    if (!u || !k) { window.setConnStatus('fail', '● Belum diatur — tap untuk atur'); return; }
    window.setConnStatus('wait', 'Menguji...');
  }
  if (u && k && navigator.onLine) {
    Bridge.flushQueue();
    try {
      const prods = await Bridge.call('getActiveProductsList', []);
      window.__kposConnected = true;
      if (window.setConnStatus) window.setConnStatus('ok', '● Online (Supabase)');
      if (window.showToast) showToast('Terkoneksi Supabase: ' + (prods ? prods.length : 0) + ' produk', 'success');
    } catch (e) {
      window.__kposConnected = false;
      if (window.setConnStatus) window.setConnStatus('fail', '● Gagal — tap untuk atur');
      if (window.showToast) showToast('Koneksi Supabase gagal: ' + e.message, 'warning');
    }
  }
}

window.addEventListener('online', () => { Bridge.flushQueue(); });
document.addEventListener('DOMContentLoaded', () => { ensureSupabase(); });
