-- ============================================================
-- KelontongPOS Marketplace: Fix 09b — HOTFIX shop_create_order
-- Jalankan di Supabase SQL Editor (mengganti fungsi shop_create_order).
-- Perbaikan: header orders dibuat SEBELUM insert order_items (urutan FK),
-- order ID diberi random, dan header dibersihkan bila validasi gagal.
-- ============================================================

create or replace function shop_create_order(p_token text, p_items json, p_note text default '', p_name text default '')
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
begin
  if v_cid is null then
    return json_build_object('ok', false, 'message', 'Sesi tidak valid. Login ulang.');
  end if;
  if coalesce(p_name,'') <> '' then
    update customers set name = p_name where id = v_cid;
  end if;

  select 'ORD-' || to_char(now() at time zone 'Asia/Jakarta','YYMMDD') || '-' ||
    lpad((abs(hashtext(v_cid || extract(epoch from now())::text || floor(random()*10000)::text)) % 9000 + 1000)::text, 4, '0')
  into v_oid;

  -- header dibuat dulu (order_items punya FK ke orders), status pending
  insert into orders (id, customer_id, total, note) values (v_oid, v_cid, 0, p_note);

  for v_item in select * from json_array_elements(coalesce(p_items, '[]'::json)) loop
    -- validasi harga & stok dari DB (bukan dari client)
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
  return json_build_object('ok', true, 'orderId', v_oid, 'total', v_total);
end;
$$;

grant execute on function shop_create_order(text,json,text,text) to anon;
