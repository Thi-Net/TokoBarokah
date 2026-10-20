# KelontongPOS

POS (Point of Sale) + Stock Opname + Cashflow untuk toko klontong.
Backend: **Supabase (Postgres)** — tanpa Google Sheets / Apps Script.

## Isi repo

| Folder | Isi |
|---|---|
| `web/` | Aplikasi versi web (dipakai juga sebagai aset WebView di APK) — **di-deploy ke Vercel** |
| `android/` | Proyek Android (WebView wrapper) — build APK dengan `gradle assembleDebug` |
| `supabase/` | SQL skema + fungsi bisnis (HPP moving average, ledger, laporan) + catatan setup |

## Menjalankan versi web

Statis — cukup serve folder `web/` (Vercel/Netlify/GitHub Pages). Di HP: buka URL →
tap badge koneksi → isi Supabase Project URL + anon key. Bisa "Add to Home Screen".

## Build APK

```bash
cd android
gradle assembleDebug      # output: app/build/outputs/apk/debug/app-debug.apk
```

## Setup Supabase (sekali)

1. Buat project di supabase.com
2. SQL Editor → jalankan `supabase/schema.sql`
3. Jalankan `supabase/fix_01_functions.sql` lalu `supabase/fix_02_rls.sql`
4. Ambil Project URL + anon key (Settings → API) → isi di aplikasi

## Keamanan

Key yang dipakai aplikasi hanyalah **anon/publishable key** (bukan service role).
Akses anon dibatasi: insert/select pada tabel data, update hanya pada
`products` & `product_units`, dan eksekusi 14 fungsi whitelisted — tanpa delete.
