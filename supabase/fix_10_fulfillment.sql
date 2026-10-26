-- ============================================================
-- KelontongPOS Marketplace: Fix 10 — fulfillment (kirim/ambil), COD,
-- jadwal & lokasi pengiriman, status pesanan baru.
-- Jalankan di Supabase SQL Editor.
-- ============================================================

-- ---------- KOLOM BARU ----------
alter table orders
  add column if not exists fulfillment text not null default 'pickup',   -- pickup|delivery
  add column if not exists address text default '',
  add column if not exists location_lat double precision,
  add column if not exists location_lng double precision,
  add column if not exists delivery_date date,
  add column if not exists delivery_slot text default '';

-- ---------- STATUS DIPERLUAS ----------
-- pending -> paid -> processing -> shipped (delivery) / ready (pickup) -> completed
-- admin flow di web menyesuaikan.

-- ---------- UPDATE RPC ----------

-- order: terima fulfillment, alamat, lokasi, jadwal; validasi jam operasional 06.00-21.00 WIB
create or replace function shop_create_order(p_token text, p_items json, p_note text default '', p_name text default '',
  p_fulfillment text default 'pickup', p_address text default '',
  p_lat double precision default null, p_lng double precision default null,
  p_delivery_date date default null, p_delivery_slot text default '')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_oid text;
  v_total numeric := 0;
  v_item json;
  v_price numeric;
  v_stock numeric;
  v_jkt time;
begin
  if v_cid is null then
    return json_build_object('ok', false, 'message', 'Sesi tidak valid. Login ulang.');
  end if;
  if coalesce(p_name,'') <> '' then
    update customers set name = p_name where id = v_cid;
  end if;

  -- jam operasional 06.00-21.00 WIB
  v_jkt := (now() at time zone 'Asia/Jakarta')::time;
  if v_jkt < '06:00' or v_jkt >= '21:00' then
    return json_build_object('ok', false, 'message', 'Toko tutup (jam operasional 06.00–21.00 WIB). Silakan pesan kembali di jam buka.');
  end if;

  -- validasi fulfillment
  if p_fulfillment not in ('pickup','delivery') then
    return json_build_object('ok', false, 'message', 'Metode pengambilan tidak valid.');
  end if;
  if p_fulfillment = 'delivery' then
    if coalesce(trim(p_address),'') = '' then
      return json_build_object('ok', false, 'message', 'Alamat lengkap wajib diisi untuk pengiriman.');
    end if;
    if p_delivery_date is null then
      return json_build_object('ok', false, 'message', 'Pilih jadwal pengiriman.');
    end if;
    if p_delivery_date < (now() at time zone 'Asia/Jakarta')::date then
      return json_build_object('ok', false, 'message', 'Jadwal pengiriman tidak boleh di masa lalu.');
    end if;
  end if;

  select 'ORD-' || to_char(now() at time zone 'Asia/Jakarta','YYMMDD') || '-' ||
    lpad((abs(hashtext(v_cid || extract(epoch from now())::text || floor(random()*10000)::text)) % 9000 + 1000)::text, 4, '0')
  into v_oid;

  insert into orders (id, customer_id, total, note, fulfillment, address, location_lat, location_lng, delivery_date, delivery_slot)
  values (v_oid, v_cid, 0, p_note, p_fulfillment,
    case when p_fulfillment = 'delivery' then trim(p_address) else '' end,
    p_lat, p_lng,
    case when p_fulfillment = 'delivery' then p_delivery_date else null end,
    case when p_fulfillment = 'delivery' then coalesce(p_delivery_slot,'') else '' end);

  for v_item in select * from json_array_elements(coalesce(p_items, '[]'::json)) loop
    select sp.price into v_price
    from selling_prices sp
    where sp.product_id = v_item->>'productId' and sp.unit_name = v_item->>'unit'
      and sp.active = true
    order by sp.effective_at desc nulls last limit 1;
    if v_price is null then
      delete from orders where id = v_oid;
      return json_build_object('ok', false, 'message', 'Harga tidak tersedia untuk ' || v_item->>'productId' || '/' || v_item->>'unit');
    end if;

    select coalesce(l.balance, 0) into v_stock
    from (select product_id, balance from (
      select product_id, balance, row_number() over (partition by product_id order by id desc) rn
      from stock_ledger) t where rn = 1) l
    where l.product_id = v_item->>'productId';
    if coalesce(v_stock, 0) < (v_item->>'qty')::numeric then
      delete from orders where id = v_oid;
      return json_build_object('ok', false, 'message', 'Stok tidak cukup untuk produk ' || v_item->>'productId');
    end if;

    insert into order_items (order_id, product_id, unit_name, qty, price_snapshot, subtotal)
    values (v_oid, v_item->>'productId', v_item->>'unit', (v_item->>'qty')::numeric,
      v_price, v_price * (v_item->>'qty')::numeric);
    v_total := v_total + v_price * (v_item->>'qty')::numeric;
  end loop;

  if v_total <= 0 then
    delete from orders where id = v_oid;
    return json_build_object('ok', false, 'message', 'Keranjang kosong.');
  end if;

  update orders set total = v_total, updated_at = now() where id = v_oid;
  return json_build_object('ok', true, 'orderId', v_oid, 'total', v_total, 'fulfillment', p_fulfillment);
end;
$$;

-- payment: tambah metode 'cod'
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
    -- COD: tidak butuh payment record aktif; tandai order langsung 'paid' dengan ref COD
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

-- my_orders: sertakan data fulfillment
create or replace function shop_my_orders(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_orders json;
  v_items json;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select coalesce(json_agg(o order by o.created_at desc), '[]'::json) into v_orders
  from orders o where o.customer_id = v_cid;
  select coalesce(json_agg(oi), '[]'::json) into v_items
  from order_items oi join orders o2 on o2.id = oi.order_id
  where o2.customer_id = v_cid;
  return json_build_object('ok', true, 'orders', v_orders, 'items', v_items);
end;
$$;

-- admin: kirim juga data fulfillment
create or replace function shop_admin_orders(p_admin_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_orders json; v_items json; v_custs json;
begin
  if coalesce(p_admin_pin,'') <> '1234' then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;
  select coalesce(json_agg(o order by o.created_at desc), '[]'::json) into v_orders from orders o;
  select coalesce(json_agg(oi), '[]'::json) into v_items from order_items oi;
  select coalesce(json_agg(c order by c.created_at desc), '[]'::json) into v_custs from customers c;
  return json_build_object('ok', true, 'orders', v_orders, 'items', v_items, 'customers', v_custs);
end;
$$;

-- admin status: shipped untuk delivery
create or replace function shop_admin_set_status(p_admin_pin text, p_order_id text, p_status text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_admin_pin,'') <> '1234' then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;
  if p_status not in ('pending','paid','processing','ready','shipped','completed','cancelled') then
    return json_build_object('ok', false, 'message', 'Status tidak valid.');
  end if;
  update orders set status = p_status, updated_at = now() where id = p_order_id;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;
  return json_build_object('ok', true, 'message', 'Status order ' || p_order_id || ' -> ' || p_status);
end;
$$;

grant execute on function
  shop_create_order(text,json,text,text,text,text,double precision,double precision,date,text),
  shop_create_payment(text,text,text),
  shop_my_orders(text),
  shop_admin_orders(text),
  shop_admin_set_status(text,text,text)
to anon;
