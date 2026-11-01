-- ============================================================
-- fix_34_catatan_piutang.sql — 3 penyesuaian dashboard admin:
-- 1) Catatan pada pembayaran POS: proses_multi_sale + param p_note,
--    catatan disimpan di sales.note (tiap item) & debts.note (bon)
-- 2) get_piutang kirim rincian item per transaksi (name/qty/unit/price/total)
-- 3) Laporan keuangan: tambah rawDebts (rincian piutang per nama, total
--    dijumlahkan per orang) + fungsi jadi security definer (RLS creditors)
-- Run di Supabase SQL Editor.
-- ============================================================

-- ---------- 1) kolom catatan ----------
alter table debts add column if not exists note text;
alter table sales add column if not exists note text;

-- ---------- 2) process_multi_sale + p_note (param ke-5, opsional) ----------
drop function if exists process_multi_sale(json);
drop function if exists process_multi_sale(json,text,text,text);
create or replace function process_multi_sale(
  p_items json,
  p_payment_method text default 'cash',
  p_creditor_id text default null,
  p_pin text default null,
  p_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
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
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
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

    insert into sales (id, product_id, unit_name, qty, qty_base, price_snapshot, total_sale, hpp_base_snapshot, total_hpp, gross_profit, payment_method, note)
    values (v_id, v_item->>'productId', v_item->>'unitName', (v_item->>'qty')::numeric, v_qty_base, v_price, v_total_sale, v_hpp, v_total_hpp, v_profit, v_method, v_note);

    v_total_profit := v_total_profit + v_profit;
    v_grand_total := v_grand_total + v_total_sale;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  -- bon: catat piutang SEKALI per transaksi (satu baris utk semua item)
  if v_method = 'bon' then
    v_debt_id := 'DBT-' || to_char(now(),'YYMMDDHH24MISS');
    insert into debts (id, creditor_id, amount, sale_ids, status, note)
    values (v_debt_id, v_creditor_id, v_grand_total, v_ids, 'open', v_note);
  end if;

  return json_build_object('status','success','saleIds', v_ids, 'totalProfit', v_total_profit,
    'paymentMethod', v_method, 'debtId', v_debt_id);
end;
$$;
grant execute on function process_multi_sale(json,text,text,text,text) to anon;

-- ---------- 3) get_piutang: + rincian item per transaksi ----------
drop function if exists get_piutang(text);
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
    'paid', coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0),
    'remaining', d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0),
    'note', d.note,
    'items', coalesce((
      select json_agg(json_build_object(
        'id', s.id, 'name', p.name, 'qty', s.qty, 'unit', s.unit_name,
        'price', s.price_snapshot, 'total', s.total_sale) order by s.created_at)
      from sales s left join products p on p.id = s.product_id
      where s.id in (select jsonb_array_elements_text(d.sale_ids))
    ), '[]'::json),
    'payments', coalesce((select json_agg(json_build_object('id', p.id, 'amount', p.amount, 'note', p.note, 'createdAt', p.created_at) order by p.created_at) from debt_payments p where p.debt_id = d.id), '[]'::json),
    'saleIds', d.sale_ids,
    'status', d.status,
    'createdAt', d.created_at,
    'paidAt', d.paid_at
  ) order by case when d.status = 'open' then 0 else 1 end, d.created_at desc), '[]'::json)
  into v_rows
  from debts d join creditors c on c.id = d.creditor_id;

  select coalesce(sum(amount),0) - coalesce((select sum(p.amount) from debt_payments p join debts d on d.id = p.debt_id where d.status = 'open'), 0)
    into v_open
  from debts where status = 'open';
  select coalesce(sum(p.amount),0) into v_paid_month
    from debt_payments p
    where (p.created_at at time zone 'Asia/Jakarta')::date >= (now() at time zone 'Asia/Jakarta')::date - interval '30 days';

  return json_build_object('ok', true, 'debts', v_rows, 'totalOpen', v_open, 'paidLast30d', v_paid_month);
end;
$$;
grant execute on function get_piutang(text) to anon;

-- ---------- 4) laporan keuangan: + rawDebts (piutang per nama) ----------
drop function if exists get_filtered_financial_report(text, date);
drop function if exists get_filtered_financial_report(date, text);
drop function if exists get_filtered_financial_report(date);
drop function if exists get_filtered_financial_report(text);
create or replace function get_filtered_financial_report(p_type text, p_date date default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_start date;
  v_end date;
  v_result json;
begin
  if p_type = 'mingguan' then
    v_start := v_date - ((extract(isodow from v_date)::int) - 1);
    v_end := v_start + 6;
  elsif p_type = 'bulanan' then
    v_start := date_trunc('month', v_date)::date;
    v_end := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;
  elsif p_type = 'tahunan' then
    v_start := date_trunc('year', v_date)::date;
    v_end := (date_trunc('year', v_date) + interval '1 year - 1 day')::date;
  else -- harian / daily (default)
    v_start := v_date; v_end := v_date;
  end if;

  select json_build_object(
    'finance', json_build_object(
      'sales', coalesce((select sum(total_sale) from sales where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0),
      'hpp', coalesce((select sum(total_hpp) from sales where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0),
      'grossProfit', coalesce((select sum(gross_profit) from sales where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0),
      'expenses', coalesce((select sum(amount) from expenses where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0),
      'purchases', coalesce((select sum(total_price) from purchases where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0),
      'netProfit', coalesce((select sum(gross_profit) from sales where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0)
                 - coalesce((select sum(amount) from expenses where (created_at at time zone 'Asia/Jakarta')::date between v_start and v_end), 0)
    ),
    'dateRange', to_char(v_start,'DD/MM/YYYY') || ' s.d. ' || to_char(v_end,'DD/MM/YYYY'),
    'rawSales', (select coalesce(json_agg(json_build_array(
        s.id, to_char(s.created_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'), p.name, s.unit_name, s.qty_base, s.price_snapshot, s.total_sale, s.total_hpp, s.gross_profit)
        order by s.created_at), '[]'::json)
      from sales s left join products p on p.id = s.product_id
      where (s.created_at at time zone 'Asia/Jakarta')::date between v_start and v_end),
    'rawPurchases', (select coalesce(json_agg(json_build_array(
        pu.id, to_char(pu.created_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'), pu.supplier, pu.invoice, pr.name, pu.unit_name, pu.qty, pu.total_price)
        order by pu.created_at), '[]'::json)
      from purchases pu left join products pr on pr.id = pu.product_id
      where (pu.created_at at time zone 'Asia/Jakarta')::date between v_start and v_end),
    'rawExpenses', (select coalesce(json_agg(json_build_array(
        e.id, to_char(e.created_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'), e.category, e.description, e.amount, e.payment_method)
        order by e.created_at), '[]'::json)
      from expenses e
      where (e.created_at at time zone 'Asia/Jakarta')::date between v_start and v_end),
    -- rincian piutang: dijumlahkan per nama (transaksi bon dibuat dalam periode)
    'rawDebts', (
      select coalesce(json_agg(json_build_object(
        'creditorName', x.creditor_name, 'count', x.cnt, 'total', x.total_amount,
        'remaining', x.total_remaining, 'lastAt', x.last_at) order by x.total_remaining desc), '[]'::json)
      from (
        select c.name as creditor_name, count(d.id) as cnt, sum(d.amount) as total_amount,
          sum(d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0)) as total_remaining,
          max(d.created_at) as last_at
        from debts d join creditors c on c.id = d.creditor_id
        where (d.created_at at time zone 'Asia/Jakarta')::date between v_start and v_end
        group by c.name
      ) x
    )
  ) into v_result;
  return v_result;
end;
$$;
grant execute on function get_filtered_financial_report(text, date) to anon;
