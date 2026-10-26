-- ============================================================
-- KelontongPOS Marketplace: Fix 09 — skema shop/customer/order/payment
-- Tabel baru (tidak menyentuh tabel POS lama).
-- Semua akses via RPC security definer (anon tidak bisa baca tabel langsung).
-- Jalankan di Supabase SQL Editor.
-- ============================================================

-- ---------- CUSTOMERS ----------
create table if not exists customers (
  id text primary key,                     -- CUS-###
  phone text unique not null,              -- format 62xxxxxxxxxx
  name text not null default '',
  otp_hash text,
  otp_expires timestamptz,
  created_at timestamptz default now()
);

-- ---------- ORDERS ----------
create table if not exists orders (
  id text primary key,                     -- ORD-YYMMDD-####
  customer_id text not null references customers(id),
  status text not null default 'pending',  -- pending|paid|processing|ready|completed|cancelled
  total numeric not null default 0,
  payment_method text default '',
  note text default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists idx_orders_customer on orders(customer_id, created_at desc);

create table if not exists order_items (
  id bigserial primary key,
  order_id text not null references orders(id) on delete cascade,
  product_id text not null references products(id),
  unit_name text not null,
  qty numeric not null,
  price_snapshot numeric not null,
  subtotal numeric not null
);

-- ---------- PAYMENTS ----------
create table if not exists payments (
  id text primary key,                     -- PAY-...
  order_id text not null references orders(id),
  provider text not null default 'demo',   -- demo|midtrans|xendit
  method text not null default 'transfer', -- transfer|qris
  amount numeric not null,
  status text not null default 'initiated',-- initiated|paid|failed|expired
  va_number text default '',
  ref text default '',
  created_at timestamptz default now(),
  paid_at timestamptz
);

-- ---------- RLS: tabel terkunci dari anon, semua via RPC ----------
alter table customers enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
alter table payments enable row level security;
revoke all on customers from anon;
revoke all on orders from anon;
revoke all on order_items from anon;
revoke all on payments from anon;

-- ============================================================
-- HELPERS
-- ============================================================
create or replace function _shop_norm_phone(p_phone text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
$$;

-- OTP demo: hash sederhana (bukan kryptografi — mode DEMO saja)
create or replace function _shop_otp_hash(p_phone text, p_otp text)
returns text language sql immutable as $$
  select encode(sha256((_shop_norm_phone(p_phone) || ':' || p_otp)::bytea), 'hex');
$$;

-- sesi customer stateless: token = 'TOK-' || customerId
create or replace function _shop_auth(p_token text)
returns text language plpgsql stable as $$
declare
  v_cid text;
begin
  if p_token like 'TOK-CUS-%' then
    v_cid := substring(p_token from 5);
    if exists(select 1 from customers where id = v_cid) then
      return v_cid;
    end if;
  end if;
  return null;
end;
$$;

-- ============================================================
-- KATALOG (publik, hanya produk aktif + stok)
-- ============================================================
create or replace function shop_catalog()
returns json
language sql
security definer
set search_path = public
as $$
  with latest as (
    select product_id, balance from (
      select product_id, balance, row_number() over (partition by product_id order by id desc) rn
      from stock_ledger
    ) t where rn = 1
  )
  select coalesce(json_agg(
    json_build_object(
      'id', p.id, 'name', p.name, 'category', p.category, 'barcode', coalesce(p.barcode,''),
      'baseUnit', p.base_unit,
      'units', pu.units,
      'prices', pr.prices,
      'stock', coalesce(l.balance, 0)
    ) order by p.category, p.name
  ), '[]'::json)
  from products p
  left join latest l on l.product_id = p.id
  left join (
    select product_id, json_agg(unit_name order by unit_name) as units
    from product_units group by product_id
  ) pu on pu.product_id = p.id
  left join (
    select product_id, json_object_agg(unit_name, price) as prices
    from (
      select distinct on (product_id, unit_name) product_id, unit_name, price
      from selling_prices where active = true
      order by product_id, unit_name, effective_at desc nulls last
    ) t group by product_id
  ) pr on pr.product_id = p.id
  where p.active = true;
$$;

-- ============================================================
-- AUTH CUSTOMER (HP + OTP, mode demo: OTP dikembalikan di respons)
-- ============================================================
create or replace function shop_request_otp(p_phone text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := _shop_norm_phone(p_phone);
  v_otp text;
  v_cust text;
begin
  if length(v_phone) < 9 or length(v_phone) > 15 then
    return json_build_object('ok', false, 'message', 'Nomor HP tidak valid.');
  end if;
  v_otp := lpad((floor(random()*900000)+100000)::text, 6, '0');

  insert into customers (id, phone, name)
  values ('CUS-' || lpad((abs(hashtext(v_phone)) % 900000 + 100000)::text, 6, '0'), v_phone, '')
  on conflict (phone) do nothing;

  select id into v_cust from customers where phone = v_phone;
  update customers set otp_hash = _shop_otp_hash(v_phone, v_otp),
    otp_expires = now() + interval '5 minutes'
  where id = v_cust;

  -- MODE DEMO: OTP dikirim dalam respons (produksi: kirim via WA/SMS gateway)
  return json_build_object('ok', true, 'message', 'Kode OTP dikirim (demo).', 'otp', v_otp);
end;
$$;

create or replace function shop_verify_otp(p_phone text, p_otp text, p_name text default '')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text := _shop_norm_phone(p_phone);
  v_cust record;
begin
  select * into v_cust from customers where phone = v_phone;
  if not found then
    return json_build_object('ok', false, 'message', 'Nomor belum terdaftar. Minta OTP dulu.');
  end if;
  if v_cust.otp_hash is null or v_cust.otp_expires is null or v_cust.otp_expires < now() then
    return json_build_object('ok', false, 'message', 'OTP kedaluwarsa. Minta ulang.');
  end if;
  if v_cust.otp_hash <> _shop_otp_hash(v_phone, p_otp) then
    return json_build_object('ok', false, 'message', 'OTP salah.');
  end if;
  update customers set otp_hash = null, otp_expires = null,
    name = case when coalesce(p_name,'') <> '' then p_name else name end
  where id = v_cust.id;
  return json_build_object('ok', true, 'customerId', v_cust.id, 'name', v_cust.name,
    'token', 'TOK-' || v_cust.id);
end;
$$;

-- ============================================================
-- ORDER
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

  -- header dibuat dulu (FK order_items -> orders), status pending
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

-- ============================================================
-- PAYMENT (provider abstraction; demo dulu)
-- ============================================================
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

  v_pid := 'PAY-' || to_char(now(),'YYMMDDHH24MISS') || '-' || floor(random()*900+100)::int;
  v_va := '8808' || lpad((abs(hashtext(p_order_id)) % 10000000000)::text, 10, '0');

  insert into payments (id, order_id, provider, method, amount, va_number)
  values (v_pid, p_order_id, 'demo', p_method, v_order.total, v_va);
  update orders set payment_method = p_method, updated_at = now() where id = p_order_id;

  return json_build_object('ok', true, 'paymentId', v_pid, 'amount', v_order.total,
    'method', p_method, 'vaNumber', v_va);
end;
$$;

-- simulasi webhook demo: tandai paid + ubah status order
create or replace function shop_pay_demo(p_token text, p_payment_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_pay record;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select p.* into v_pay from payments p join orders o on o.id = p.order_id
    where p.id = p_payment_id and o.customer_id = v_cid;
  if not found then return json_build_object('ok', false, 'message', 'Payment tidak ditemukan.'); end if;
  if v_pay.status = 'paid' then return json_build_object('ok', true, 'message', 'Sudah dibayar.'); end if;

  update payments set status = 'paid', paid_at = now(), ref = 'DEMO-SIM' where id = p_payment_id;
  update orders set status = 'paid', updated_at = now() where id = v_pay.order_id;
  return json_build_object('ok', true, 'message', 'Pembayaran (demo) berhasil. Status order: paid.');
end;
$$;

create or replace function shop_cancel_order(p_token text, p_order_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  update orders set status = 'cancelled', updated_at = now()
  where id = p_order_id and customer_id = v_cid and status = 'pending';
  if not found then return json_build_object('ok', false, 'message', 'Order tidak bisa dibatalkan.'); end if;
  return json_build_object('ok', true, 'message', 'Order dibatalkan.');
end;
$$;

-- ============================================================
-- ADMIN (dipanggil dari POS tab "Pesanan Online")
-- DEMO: PIN hard-coded '1234'. Produksi: pindah ke tabel config terpisah.
-- ============================================================
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
  if p_status not in ('pending','paid','processing','ready','completed','cancelled') then
    return json_build_object('ok', false, 'message', 'Status tidak valid.');
  end if;
  update orders set status = p_status, updated_at = now() where id = p_order_id;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;
  return json_build_object('ok', true, 'message', 'Status order ' || p_order_id || ' -> ' || p_status);
end;
$$;

-- ============================================================
-- GRANT
-- ============================================================
grant execute on function
  shop_catalog(),
  shop_request_otp(text),
  shop_verify_otp(text,text,text),
  shop_create_order(text,json,text,text),
  shop_my_orders(text),
  shop_create_payment(text,text,text),
  shop_pay_demo(text,text),
  shop_cancel_order(text,text),
  shop_admin_orders(text),
  shop_admin_set_status(text,text,text)
to anon;
