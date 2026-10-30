-- ============================================================
-- fix_29_piutang.sql — Jenis pembayaran POS (cash/qris/bon) + Piutang
-- 1) sales.payment_method (default 'cash')
-- 2) tabel creditors (nama peminjam/bon) + debts (piutang)
-- 3) process_multi_sale versi baru: p_payment_method, p_creditor_id, p_pin
-- 4) RPC pendukung: get_creditors, add_creditor, get_piutang, pay_debt
-- Run di Supabase SQL Editor.
-- ============================================================

-- ---------- 1) kolom payment_method di sales ----------
alter table sales add column if not exists payment_method text default 'cash';

-- ---------- 2) tabel creditors & debts ----------
create table if not exists creditors (
  id text primary key,
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table if not exists debts (
  id text primary key,                     -- DBT-...
  creditor_id text not null references creditors(id),
  amount numeric not null,
  sale_ids jsonb not null default '[]'::jsonb,
  status text not null default 'open',     -- open | paid
  created_at timestamptz default now(),
  paid_at timestamptz
);
create index if not exists idx_debts_status on debts(status, created_at desc);

-- ---------- 3) process_multi_sale dgn metode bayar ----------
drop function if exists process_multi_sale(json);
create or replace function process_multi_sale(
  p_items json,
  p_payment_method text default 'cash',
  p_creditor_id text default null,
  p_pin text default null
)
returns json
language plpgsql
as $$
declare
  v_item jsonb;
  v_conv numeric;
  v_qty_base numeric;
  v_stock numeric;
  v_hpp numeric;
  v_price numeric;
  v_total_sale numeric;
  v_total_hpp numeric;
  v_profit numeric;
  v_total_profit numeric := 0;
  v_grand_total numeric := 0;
  v_ids jsonb := '[]'::jsonb;
  v_id text;
  v_method text := lower(coalesce(p_payment_method, 'cash'));
  v_creditor_id text;
  v_debt_id text;
  v_stored_pin text;
begin
  if v_method not in ('cash','qris','bon') then
    raise exception 'Metode pembayaran tidak dikenal: %', v_method;
  end if;

  if v_method = 'bon' then
    if p_creditor_id is null then
      raise exception 'Pembayaran bon wajib memilih nama peminjam';
    end if;
    select value into v_stored_pin from app_settings where key = 'admin_pin';
    if v_stored_pin is null or p_pin is null or p_pin <> v_stored_pin then
      raise exception 'PIN Admin salah — pembayaran bon butuh verifikasi';
    end if;
    if not exists (select 1 from creditors where id = p_creditor_id) then
      raise exception 'Nama peminjam tidak ditemukan';
    end if;
    v_creditor_id := p_creditor_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items::jsonb)
  loop
    select conversion_rate into v_conv from product_units
    where product_id = v_item->>'productId' and lower(unit_name) = lower(v_item->>'unitName');
    if v_conv is null then
      raise exception 'Satuan % tidak ditemukan untuk %', v_item->>'unitName', v_item->>'productId';
    end if;

    v_qty_base := (v_item->>'qty')::numeric * v_conv;

    select balance, hpp_avg into v_stock, v_hpp
    from stock_ledger where product_id = v_item->>'productId' order by id desc limit 1;
    v_stock := coalesce(v_stock, 0);
    v_hpp := coalesce(v_hpp, 0);

    if v_stock < v_qty_base then
      raise exception 'Stok kurang untuk %: sisa %', v_item->>'productId', v_stock;
    end if;

    select price into v_price from selling_prices
    where product_id = v_item->>'productId' and lower(unit_name) = lower(v_item->>'unitName') and active = true
    order by effective_at desc limit 1;
    if v_price is null then raise exception 'Harga belum diatur untuk %', v_item->>'productId'; end if;

    v_id := 'SLS-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
    v_total_sale := (v_item->>'qty')::numeric * v_price;
    v_total_hpp := v_qty_base * v_hpp;
    v_profit := v_total_sale - v_total_hpp;

    perform record_stock_ledger(v_item->>'productId', 'SALE', v_id, 0, v_qty_base, 0);

    insert into sales (id, product_id, unit_name, qty, qty_base, price_snapshot, total_sale, hpp_base_snapshot, total_hpp, gross_profit, payment_method)
    values (v_id, v_item->>'productId', v_item->>'unitName', (v_item->>'qty')::numeric, v_qty_base, v_price, v_total_sale, v_hpp, v_total_hpp, v_profit, v_method);

    v_total_profit := v_total_profit + v_profit;
    v_grand_total := v_grand_total + v_total_sale;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  -- bon: catat piutang SEKALI per transaksi (satu baris utk semua item)
  if v_method = 'bon' then
    v_debt_id := 'DBT-' || to_char(now(),'YYMMDDHH24MISS');
    insert into debts (id, creditor_id, amount, sale_ids, status)
    values (v_debt_id, v_creditor_id, v_grand_total, v_ids, 'open');
  end if;

  return json_build_object('status','success','saleIds', v_ids, 'totalProfit', v_total_profit,
    'paymentMethod', v_method, 'debtId', v_debt_id);
end;
$$;

-- ---------- 4a) daftar nama peminjam ----------
create or replace function get_creditors()
returns json
language sql
as $$
  select coalesce(json_agg(row_to_json(t) order by t.name), '[]'::json)
  from (select id, name, phone, created_at from creditors order by name) t;
$$;

-- ---------- 4b) tambah nama peminjam (PIN-guard) ----------
create or replace function add_creditor(p_pin text, p_name text, p_phone text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_id text;
  v_name text := btrim(p_name);
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  if v_name = '' then
    return json_build_object('ok', false, 'message', 'Nama wajib diisi');
  end if;
  if exists (select 1 from creditors where lower(name) = lower(v_name)) then
    return json_build_object('ok', false, 'message', 'Nama "' || v_name || '" sudah ada');
  end if;
  v_id := 'CDR-' || to_char(now(),'YYMMDD') || '-' || floor(random()*900+100)::int;
  insert into creditors (id, name, phone) values (v_id, v_name, nullif(btrim(coalesce(p_phone,'')), ''));
  return json_build_object('ok', true, 'id', v_id, 'name', v_name);
end;
$$;

-- ---------- 4c) daftar piutang ----------
create or replace function get_piutang(p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_rows json;
  v_open numeric;
  v_paid_month numeric;
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  select coalesce(json_agg(json_build_object(
    'id', d.id,
    'creditorId', d.creditor_id,
    'creditorName', c.name,
    'amount', d.amount,
    'saleIds', d.sale_ids,
    'status', d.status,
    'createdAt', d.created_at,
    'paidAt', d.paid_at
  ) order by case when d.status = 'open' then 0 else 1 end, d.created_at desc), '[]'::json)
  into v_rows
  from debts d join creditors c on c.id = d.creditor_id;

  select coalesce(sum(amount),0) into v_open from debts where status = 'open';
  select coalesce(sum(amount),0) into v_paid_month
    from debts where status = 'paid' and (paid_at at time zone 'Asia/Jakarta')::date >= (now() at time zone 'Asia/Jakarta')::date - interval '30 days';

  return json_build_object('ok', true, 'debts', v_rows, 'totalOpen', v_open, 'paidLast30d', v_paid_month);
end;
$$;

-- ---------- 4d) tandai lunas ----------
create or replace function pay_debt(p_pin text, p_debt_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  if not exists (select 1 from debts where id = p_debt_id and status = 'open') then
    return json_build_object('ok', false, 'message', 'Piutang tidak ditemukan / sudah lunas');
  end if;
  update debts set status = 'paid', paid_at = now() where id = p_debt_id;
  return json_build_object('ok', true, 'message', 'Piutang ' || p_debt_id || ' ditandai lunas');
end;
$$;

-- ---------- grant anon (dipakai web /pos via publishable key) ----------
grant execute on function process_multi_sale(json,text,text,text) to anon;
grant execute on function get_creditors() to anon;
grant execute on function add_creditor(text,text,text) to anon;
grant execute on function get_piutang(text) to anon;
grant execute on function pay_debt(text,text) to anon;
