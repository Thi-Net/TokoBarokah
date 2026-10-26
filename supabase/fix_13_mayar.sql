-- ============================================================
-- KelontongPOS Marketplace: Fix 13 — integrasi Mayar payment gateway
-- 1) Kolom penyimpanan transaksi Mayar di tabel payments
-- 2) RPC shop_confirm_mayar_payment: handler "Payment Sukses" untuk
--    webhook Mayar (idempotent) — status paid, stok berkurang,
--    penjualan tercatat di POS. Tidak mengubah tabel/skema lain.
-- Jalankan di Supabase SQL Editor.
-- ============================================================

alter table payments add column if not exists mayar_transaction_id text;
alter table payments add column if not exists mayar_link text;
create index if not exists payments_mayar_txn_idx on payments (mayar_transaction_id);

-- Konfirmasi pembayaran Mayar via webhook: idempotent.
-- Dipanggil Edge Function mayar-webhook (service role), TIDAK dibuka ke anon.
create or replace function shop_confirm_mayar_payment(p_transaction_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay record;
  v_ord record;
begin
  select * into v_pay from payments where mayar_transaction_id = p_transaction_id limit 1;
  if not found then
    return json_build_object('ok', false, 'message', 'Transaksi Mayar tidak dikenal: ' || p_transaction_id);
  end if;

  select * into v_ord from orders where id = v_pay.order_id for update;
  if not found then
    return json_build_object('ok', false, 'message', 'Order tidak ditemukan.');
  end if;

  -- IDEMPOTENT: order yang sudah paid/completed diabaikan (webhook duplikat
  -- tidak memicu pengurangan stok / penjualan dua kali).
  if v_ord.status in ('paid','processing','ready','shipping','completed','cancelled') then
    -- pastikan payment tercatat paid, lalu selesai tanpa menyentuh stok
    if v_pay.status <> 'paid' then
      update payments set status = 'paid', paid_at = coalesce(paid_at, now()), ref = 'MAYAR-WEBHOOK'
      where id = v_pay.id;
    end if;
    return json_build_object('ok', true, 'message', 'Sudah diproses sebelumnya (idempotent).');
  end if;

  if v_ord.status <> 'pending' then
    return json_build_object('ok', false, 'message', 'Status order tidak valid: ' || v_ord.status);
  end if;

  -- Handler Payment Sukses yang sudah ada (dari fix_11): kurangi stok via
  -- stock_ledger + catat penjualan POS. Bisa raise (stok kurang) -> webhook
  -- retry nanti; payment belum ditandai paid di titik ini.
  perform _shop_fulfill_order_stock(v_pay.order_id, 'MAYAR-' || v_pay.id);

  update payments set status = 'paid', paid_at = now(), ref = 'MAYAR-' || p_transaction_id
  where id = v_pay.id;
  update orders set status = 'paid', updated_at = now() where id = v_pay.order_id;

  return json_build_object('ok', true, 'message', 'Pembayaran Mayar terkonfirmasi untuk ' || v_pay.order_id);
end;
$$;

-- Catatan akses:
-- - shop_confirm_mayar_payment TIDAK di-grant ke anon (hanya service role
--   Edge Function mayar-webhook yang memanggilnya).
-- - Order flow customer tetap via RPC shop_* yang sudah ada.
