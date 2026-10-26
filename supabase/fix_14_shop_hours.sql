-- ============================================================
-- KelontongPOS Marketplace: Fix 14 — jam operasional diperlonggar
-- Transaksi online bisa 24 jam. Yang dibatasi hanya slot 'langsung'
-- (diproses segera) — hanya sah saat toko buka 06.00-21.00 WIB.
-- Di luar jam, customer memilih jadwal pengiriman (mulai besok).
-- Jalankan di Supabase SQL Editor.
-- ============================================================

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
  v_buka boolean;
begin
  if v_cid is null then
    return json_build_object('ok', false, 'message', 'Sesi tidak valid. Login ulang.');
  end if;
  if coalesce(p_name,'') <> '' then
    update customers set name = p_name where id = v_cid;
  end if;

  -- jam operasional 06.00-21.00 WIB: transaksi online TETAP bisa 24 jam.
  -- yang dibatasi hanya slot 'langsung' (pesanan diproses segera):
  -- hanya sah saat toko buka. Di luar jam, customer wajib pilih jadwal besok.
  v_jkt := (now() at time zone 'Asia/Jakarta')::time;
  v_buka := (v_jkt >= '06:00' and v_jkt < '21:00');
  if p_fulfillment = 'delivery' and coalesce(p_delivery_slot,'') = 'langsung' and not v_buka then
    return json_build_object('ok', false, 'message', 'Toko sedang tutup (06.00–21.00 WIB). Pilih jadwal pengiriman besok.');
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

grant execute on function shop_create_order(text,json,text,text,text,text,double precision,double precision,date,text) to anon;
