-- ============================================================
-- KelontongPOS Fix 12: status 'shipped' -> 'shipping'
-- Jalankan di Supabase SQL Editor.
-- ============================================================

create or replace function shop_admin_set_status(p_admin_pin text, p_order_id text, p_status text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ord record;
begin
  if coalesce(p_admin_pin,'') <> '1234' then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;
  if p_status not in ('pending','paid','processing','ready','shipping','completed','cancelled') then
    return json_build_object('ok', false, 'message', 'Status tidak valid.');
  end if;
  select * into v_ord from orders where id = p_order_id for update;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;

  -- COD: transaksi final HANYA saat admin konfirmasi 'completed'
  -- (customer sudah ambil barang & bayar tunai di kasir). Di titik ini stok
  -- dikurangi + penjualan tercatat. Tidak otomatis saat customer memesan.
  if p_status = 'completed' and v_ord.payment_method = 'cod'
     and v_ord.status not in ('completed','cancelled') then
    perform _shop_fulfill_order_stock(p_order_id, 'COD-' || p_order_id);
  end if;

  update orders set status = p_status, updated_at = now() where id = p_order_id;
  return json_build_object('ok', true, 'message', 'Status order ' || p_order_id || ' -> ' || p_status);
end;
$$;

grant execute on function shop_admin_set_status(text,text,text) to anon;
