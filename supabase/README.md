# KelontongPOS — Migrasi ke Supabase

## Langkah setup (dilakukan user / operator)
1. Daftar di https://supabase.com → New project (region: Singapore)
2. Dashboard → SQL Editor → New query → paste seluruh isi `schema.sql` → Run
3. Ambil dari Project Settings → API:
   - Project URL: `https://xxxx.supabase.co`
   - anon public key (bukan service_role)
4. Kirim URL + anon key ke agent (aman, anon key bukan rahasia)

## Migrasi data dari Google Sheets
Script `migrate_data.py` membaca sheet via Web App (get_raw_table-twin di Apps Script)
dan memasukkan ke Supabase via PostgREST. Jalankan: `python3 migrate_data.py <SUPABASE_URL> <ANON_KEY> <SHEET_EXEC_URL>`

## Perubahan app
- `app-bridge.js` → Bridge.call memakai Supabase RPC (`/rest/v1/rpc/<fn>`)
  dengan header `apikey` dan `Authorization: Bearer <anon>`.
- Nama fungsi snake_case (port dari camelCase Apps Script):
  process_multi_sale, process_purchase, process_stock_opname, process_expense,
  add_new_product, add_new_unit_to_product, update_selling_price,
  get_dashboard_summary, get_active_products_list, get_daily_omzet_data,
  get_filtered_financial_report, get_stock_ledger_data, check_product_exists, get_raw_table.
- Antrean offline tetap sama; saat flush, panggilan RPC POST ke Supabase.

## Rollback
Google Sheets + Apps Script tetap utuh dan bisa dipakai kapan pun — cukup kembali
pakai URL Web App di menu Sinkron & URL (perlu mode bridge "sheets", lihat konfigurasi).
