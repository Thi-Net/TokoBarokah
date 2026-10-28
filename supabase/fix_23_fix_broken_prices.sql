-- fix_23_fix_broken_prices.sql — perbaiki 29 produk dengan harga 9/0 (rusak oleh
-- parseFloat('9.000') & satuan duplikat, Okt 2026). Harga baru = harga pasar wajar,
-- sudah disetujui pemilik. Jalankan di Supabase SQL Editor.

begin;

-- 1. Nonaktifkan semua harga lama yang bermasalah (harga <= 9)
update selling_prices
set active = false
where active = true and price <= 9;

-- 2. Insert harga baru (harga pasar Banyuwangi)
insert into selling_prices (id, product_id, unit_name, price, effective_at, active) values
  ('PRC-261028-001', 'PRD-025', 'Pcs', 2000, now(), true),
  ('PRC-261028-002', 'PRD-025', 'pack', 15000, now(), true),
  ('PRC-261028-003', 'PRD-082', 'Pcs', 1000, now(), true),
  ('PRC-261028-004', 'PRD-076', 'Pcs', 1000, now(), true),
  ('PRC-261028-005', 'PRD-135', '500 gr', 7000, now(), true),
  ('PRC-261028-006', 'PRD-057', 'Pcs', 18000, now(), true),
  ('PRC-261028-007', 'PRD-124', 'Pcs', 4500, now(), true),
  ('PRC-261028-008', 'PRD-125', 'Pcs', 4000, now(), true),
  ('PRC-261028-009', 'PRD-126', 'Pcs', 4000, now(), true),
  ('PRC-261028-010', 'PRD-077', 'Pcs', 2500, now(), true),
  ('PRC-261028-011', 'PRD-159', 'Pcs', 1500, now(), true),
  ('PRC-261028-012', 'PRD-162', 'Pcs', 2500, now(), true),
  ('PRC-261028-013', 'PRD-160', 'Pcs', 2500, now(), true),
  ('PRC-261028-014', 'PRD-161', 'Pcs', 3000, now(), true),
  ('PRC-261028-015', 'PRD-099', 'Pcs', 12000, now(), true),
  ('PRC-261028-016', 'PRD-084', 'Pcs', 5000, now(), true),
  ('PRC-261028-017', 'PRD-080', 'Pcs', 1000, now(), true),
  ('PRC-261028-018', 'PRD-023', 'Pcs', 2000, now(), true),
  ('PRC-261028-019', 'PRD-151', 'Pcs', 22000, now(), true),
  ('PRC-261028-020', 'PRD-022', 'Pcs', 2000, now(), true),
  ('PRC-261028-021', 'PRD-132', 'Pcs', 3000, now(), true),
  ('PRC-261028-022', 'PRD-055', 'Pcs', 16000, now(), true),
  ('PRC-261028-023', 'PRD-056', 'Pcs', 16000, now(), true),
  ('PRC-261028-024', 'PRD-092', 'Pcs', 6000, now(), true),
  ('PRC-261028-025', 'PRD-155', 'Pcs', 5000, now(), true),
  ('PRC-261028-026', 'PRD-156', 'Pcs', 5000, now(), true),
  ('PRC-261028-027', 'PRD-024', 'Pcs', 2000, now(), true),
  ('PRC-261028-028', 'PRD-071', 'Pcs', 1000, now(), true),
  ('PRC-261028-029', 'PRD-091', '250gr', 5000, now(), true),
  ('PRC-261028-030', 'PRD-049', '250gr', 6000, now(), true),
  ('PRC-261028-031', 'PRD-049', '100gr', 3000, now(), true)

on conflict (id) do nothing;

commit;

-- Verifikasi (jalankan terpisah setelah commit):
-- select count(*) from selling_prices where active = true and price <= 9;  -- harus 0
