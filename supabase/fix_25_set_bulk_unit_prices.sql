-- fix_25_set_bulk_unit_prices.sql — set harga utk 9 satuan besar (dus/karton/pack/tray)
-- yang belum berharga. Hitungan dari harga ecer dikurangi diskon grosir ~5%,
-- konversi isi disetujui pemilik. Jalankan di Supabase SQL Editor.

begin;

insert into selling_prices (id, product_id, unit_name, price, effective_at, active) values
  ('PRC-261028C-001', 'PRD-003', 'dus', 228000, now(), true),
  ('PRC-261028C-002', 'PRD-004', 'dus', 205000, now(), true),
  ('PRC-261028C-003', 'PRD-005', 'dus', 191000, now(), true),
  ('PRC-261028C-004', 'PRD-006', 'dus', 40000, now(), true),
  ('PRC-261028C-005', 'PRD-007', 'karton', 172000, now(), true),
  ('PRC-261028C-006', 'PRD-010', 'tray', 150000, now(), true),
  ('PRC-261028C-007', 'PRD-011', 'pack', 20000, now(), true),
  ('PRC-261028C-008', 'PRD-011', 'pcs', 2000, now(), true),
  ('PRC-261028C-009', 'PRD-107', 'pcs', 3000, now(), true)

on conflict (id) do nothing;

commit;
