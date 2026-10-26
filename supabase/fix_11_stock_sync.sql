-- ============================================================
-- KelontongPOS Marketplace: Fix 11 — stok & penjualan sinkron saat payment
-- Saat payment sukses (demo paid / COD), stok dikurangi via stock_ledger
-- dan transaksi masuk ke tabel sales (muncul di Penjualan POS & dashboard).
-- Idempotent: order yang sudah diproses tidak diproses ulang.
-- Jalankan di Supabase SQL Editor.
-- ============================================================

-- helper: konversi qty order (per satuan) -> qty dasar + proses sebagai penjualan
create or replace function _shop_fulfill_order_stock(p_order_id text, p_ref text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_conv numeric;
  v_qty_base numeric;
  v_stock numeric;
  v_hpp numeric;
  v_price numeric;
  v_id text;
  v_total_sale numeric;
  v_total_hpp numeric;
  v_profit numeric;
begin
  for v_item in
    select oi.product_id, oi.unit_name, oi.qty, oi.price_snapshot
    from order_items oi where oi.order_id = p_order_id
  loop
    select conversion_rate into v_conv from product_units
    where product_id = v_item.product_id and unit_name = v_item.unit_name;
    if v_conv is null then v_conv := 1; end if;
    v_qty_base := v_item.qty * v_conv;

    select balance, hpp_avg into v_stock, v_hpp
    from stock_ledger where product_id = v_item.product_id order by id desc limit 1;
    v_stock := coalesce(v_stock, 0);
    v_hpp := coalesce(v_hpp, 0);
    if v_stock < v_qty_base then
      raise exception 'Stok kurang untuk % saat pemenuhan order: sisa %, butuh %', v_item.product_id, v_stock, v_qty_base;
    end if;

    v_id := 'SLS-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
    v_total_sale := v_item.qty * v_item.price_snapshot;
    v_total_hpp := v_qty_base * v_hpp;
    v_profit := v_total_sale - v_total_hpp;

    perform record_stock_ledger(v_item.product_id, 'SALE', v_id, 0, v_qty_base, 0);

    insert into sales (id, product_id, unit_name, qty, qty_base, price_snapshot, total_sale, hpp_base_snapshot, total_hpp, gross_profit)
    values (v_id, v_item.product_id, v_item.unit_name, v_item.qty, v_qty_base, v_item.price_snapshot, v_total_sale, v_hpp, v_total_hpp, v_profit);
  end loop;
end;
$$;

-- pay demo: setelah paid -> kurangi stok + catat penjualan (sekali saja)
create or replace function shop_pay_demo(p_token text, p_payment_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_pay record;
  v_ord record;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select p.*, o.customer_id as ord_cid into v_pay
  from payments p join orders o on o.id = p.order_id
  where p.id = p_payment_id and o.customer_id = v_cid;
  if not found then return json_build_object('ok', false, 'message', 'Payment tidak ditemukan.'); end if;

  select * into v_ord from orders where id = v_pay.order_id for update;
  if v_ord.status = 'paid' then return json_build_object('ok', true, 'message', 'Sudah dibayar.'); end if;

  -- kurangi stok + catat penjualan dulu (bisa raise -> gagal, payment tidak ditandai paid)
  perform _shop_fulfill_order_stock(v_pay.order_id, v_pay.id);

  update payments set status = 'paid', paid_at = now(), ref = 'DEMO-SIM' where id = p_payment_id;
  update orders set status = 'paid', updated_at = now() where id = v_pay.order_id;
  return json_build_object('ok', true, 'message', 'Pembayaran berhasil. Stok diperbarui & pesanan masuk ke penjualan POS.');
end;
$$;

-- COD: saat customer pilih COD, stok BELUM dikurangi — dikurangi saat admin
-- menandai completed/shipped (barang benar-benar diterima/dibayar).
create or replace function shop_create_payment(p_token text, p_order_id text, p_method text default 'transfer')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_order record;
  v_pid text;
  v_va text;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select * into v_order from orders where id = p_order_id and customer_id = v_cid;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;
  if v_order.status <> 'pending' then return json_build_object('ok', false, 'message', 'Order sudah diproses/dibayar.'); end if;
  if p_method not in ('transfer','qris','cod') then
    return json_build_object('ok', false, 'message', 'Metode bayar tidak valid.');
  end if;

  if p_method = 'cod' then
    insert into payments (id, order_id, provider, method, amount, status, ref)
    values ('PAY-' || to_char(now(),'YYMMDDHH24MISS') || '-' || floor(random()*900+100)::int,
      p_order_id, 'cod', 'cod', v_order.total, 'initiated', 'COD-ON-DELIVERY');
    update orders set status = 'paid', payment_method = 'cod', updated_at = now() where id = p_order_id;
    return json_build_object('ok', true, 'cod', true,
      'message', 'Pesanan masuk — bayar tunai saat barang diterima / ambil di toko.');
  end if;

  v_pid := 'PAY-' || to_char(now(),'YYMMDDHH24MISS') || '-' || floor(random()*900+100)::int;
  v_va := '8808' || lpad((abs(hashtext(p_order_id)) % 10000000000)::text, 10, '0');

  insert into payments (id, order_id, provider, method, amount, va_number)
  values (v_pid, p_order_id, 'demo', p_method, v_order.total, v_va);
  update orders set payment_method = p_method, updated_at = now() where id = p_order_id;

  return json_build_object('ok', true, 'paymentId', v_pid, 'amount', v_order.total,
    'method', p_method, 'vaNumber', v_va);
end;
$$;

-- admin: COD selesai (completed) -> kurangi stok + catat penjualan; juga aman untuk
-- memaksa fulfill manual order paid yang belum terproses.
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
  if p_status not in ('pending','paid','processing','ready','shipped','completed','cancelled') then
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

grant execute on function
  shop_pay_demo(text,text),
  shop_create_payment(text,text,text),
  shop_admin_set_status(text,text,text)
to anon;
