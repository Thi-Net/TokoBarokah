-- ============================================================
-- KelontongPOS Fix 05 (21 Okt 2026): ZONA WAKTU WIB
-- Semua agregasi tanggal memakai Asia/Jakarta, bukan UTC
-- (bug: penjualan 10:50 WIB tercatat jam 03:50 di omzet harian)
-- ============================================================

drop function if exists get_filtered_financial_report(text, date);
drop function if exists get_filtered_financial_report(text);
drop function if exists get_dashboard_summary();
drop function if exists get_daily_omzet_data(date);
drop function if exists get_stock_ledger_data(date);

-- ---------- get_dashboard_summary ----------
create or replace function get_dashboard_summary()
returns json
language plpgsql
as $$
declare
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_result json;
begin
  with latest as (
    select product_id, balance from (
      select product_id, balance,
             row_number() over (partition by product_id order by id desc) rn
      from stock_ledger
    ) t where rn = 1
  ),
  health as (
    select
      count(*) filter (where l.balance > 5) as safe,
      count(*) filter (where l.balance > 0 and l.balance <= 5) as low,
      count(*) filter (where l.balance <= 0) as critical
    from latest l
    join products p on p.id = l.product_id
    where p.active = true
  ),
  lowitems as (
    select coalesce(json_agg(json_build_object('name', x.name, 'stock', x.stock) order by x.stock), '[]'::json) as items
    from (
      select p.name, l.balance as stock
      from latest l
      join products p on p.id = l.product_id
      where p.active = true and l.balance <= 5
      order by l.balance asc
      limit 5
    ) x
  ),
  days as (
    select generate_series(v_today - 6, v_today, interval '1 day')::date as d
  ),
  daily as (
    select days.d,
           coalesce((select sum(total_sale) from sales s
             where (s.created_at at time zone 'Asia/Jakarta')::date = days.d), 0) as omzet
    from days
  )
  select json_build_object(
    'finance', json_build_object(
      'sales', coalesce((select sum(total_sale) from sales where (created_at at time zone 'Asia/Jakarta')::date = v_today), 0),
      'purchases', coalesce((select sum(total_price) from purchases where (created_at at time zone 'Asia/Jakarta')::date = v_today), 0),
      'grossProfit', coalesce((select sum(gross_profit) from sales where (created_at at time zone 'Asia/Jakarta')::date = v_today), 0),
      'netProfit', coalesce((select sum(gross_profit) from sales where (created_at at time zone 'Asia/Jakarta')::date = v_today), 0)
                 - coalesce((select sum(amount) from expenses where (created_at at time zone 'Asia/Jakarta')::date = v_today), 0)
    ),
    'inventoryHealth', json_build_object(
      'safe', h.safe, 'low', h.low, 'critical', h.critical,
      'items', li.items
    ),
    'chart', json_build_object(
      'labels', (select json_agg(to_char(d, 'DD/MM')) from daily),
      'data', (select json_agg(omzet) from daily)
    )
  )
  into v_result
  from health h cross join lowitems li;
  return v_result;
end;
$$;

-- ---------- get_daily_omzet_data ----------
create or replace function get_daily_omzet_data(p_date date default null)
returns json
language plpgsql
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
begin
  return coalesce(json_agg(json_build_object(
    'time', to_char(s.created_at at time zone 'Asia/Jakarta', 'HH24:MI'),
    'datetime', to_char(s.created_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'),
    'product', p.name,
    'unit', s.unit_name,
    'qty', s.qty_base,
    'total', s.total_sale,
    'profit', s.gross_profit
  ) order by s.created_at), '[]'::json)
  from sales s
  left join products p on p.id = s.product_id
  where (s.created_at at time zone 'Asia/Jakarta')::date = v_date;
end;
$$;

-- ---------- get_filtered_financial_report ----------
create or replace function get_filtered_financial_report(p_type text, p_date date default null)
returns json
language plpgsql
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
  v_start date;
  v_end date;
  v_result json;
begin
  if p_type = 'daily' then
    v_start := v_date; v_end := v_date;
  elsif p_type = 'monthly' then
    v_start := date_trunc('month', v_date)::date;
    v_end := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;
  elsif p_type = 'yearly' then
    v_start := date_trunc('year', v_date)::date;
    v_end := (date_trunc('year', v_date) + interval '1 year - 1 day')::date;
  else
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
      where (e.created_at at time zone 'Asia/Jakarta')::date between v_start and v_end)
  ) into v_result;
  return v_result;
end;
$$;

-- ---------- get_stock_ledger_data (jam WIB juga) ----------
create or replace function get_stock_ledger_data(p_date date default null)
returns json
language plpgsql
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date);
begin
  return coalesce(json_agg(json_build_object(
    'time', to_char(l.created_at at time zone 'Asia/Jakarta', 'HH24:MI'),
    'datetime', to_char(l.created_at at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'),
    'product', p.name,
    'refType', l.ref_type,
    'qtyIn', l.qty_in,
    'qtyOut', l.qty_out,
    'balance', l.balance,
    'hpp', l.hpp_avg,
    'value', l.inventory_value
  ) order by l.created_at), '[]'::json)  from stock_ledger l
  left join products p on p.id = l.product_id
  where (l.created_at at time zone 'Asia/Jakarta')::date = v_date;
end;
$$;
