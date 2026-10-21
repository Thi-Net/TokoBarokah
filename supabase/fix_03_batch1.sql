-- ============================================================
-- KelontongPOS Fix Batch 1 (21 Okt 2026)
-- 1) dashboard: tambah chart (7 hari) — perbaiki "reading labels"
-- 2) POS: perbaiki bug json||json di process_multi_sale (v_ids)
-- 3) raw table: kolom PRODUCTS null (v_cols tak terisi) → isi ulang
-- 4) raw PRODUCT_UNITS & lainnya: pastikan kolom tersedia
-- ============================================================

-- ---------- 1) get_dashboard_summary + chart ----------
create or replace function get_dashboard_summary()
returns json
language plpgsql
as $$
declare
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
  -- grafik 7 hari terakhir
  days as (
    select generate_series(current_date - 6, current_date, interval '1 day')::date as d
  ),
  daily as (
    select days.d,
           coalesce((select sum(total_sale) from sales s where s.created_at::date = days.d), 0) as omzet
    from days
  )
  select json_build_object(
    'finance', json_build_object(
      'sales', coalesce((select sum(total_sale) from sales where created_at::date = current_date), 0),
      'purchases', coalesce((select sum(total_price) from purchases where created_at::date = current_date), 0),
      'grossProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0),
      'netProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0)
                 - coalesce((select sum(amount) from expenses where created_at::date = current_date), 0)
    ),
    'chart', json_build_object(
      'labels', (select json_agg(to_char(d, 'DD Mon')) from daily),
      'data', (select json_agg(omzet) from daily)
    ),
    'inventoryHealth', json_build_object(
      'safe', h.safe, 'low', h.low, 'critical', h.critical,
      'items', li.items
    )
  )
  into v_result
  from health h cross join lowitems li;
  return v_result;
end;
$$;

-- ---------- 2) process_multi_sale: fix json || json ----------
create or replace function process_multi_sale(p_items json)
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
  v_ids jsonb := '[]'::jsonb;
  v_id text;
begin
  for v_item in select * from jsonb_array_elements(p_items::jsonb)
  loop
    select conversion_rate into v_conv from product_units
    where product_id = v_item->>'productId' and unit_name = v_item->>'unitName';
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
    where product_id = v_item->>'productId' and unit_name = v_item->>'unitName' and active = true
    order by effective_at desc limit 1;
    if v_price is null then raise exception 'Harga belum diatur untuk %', v_item->>'productId'; end if;

    v_id := 'SLS-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
    v_total_sale := (v_item->>'qty')::numeric * v_price;
    v_total_hpp := v_qty_base * v_hpp;
    v_profit := v_total_sale - v_total_hpp;

    perform record_stock_ledger(v_item->>'productId', 'SALE', v_id, 0, v_qty_base, 0);

    insert into sales (id, product_id, unit_name, qty, qty_base, price_snapshot, total_sale, hpp_base_snapshot, total_hpp, gross_profit)
    values (v_id, v_item->>'productId', v_item->>'unitName', (v_item->>'qty')::numeric, v_qty_base, v_price, v_total_sale, v_hpp, v_total_hpp, v_profit);

    v_total_profit := v_total_profit + v_profit;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  return json_build_object('status','success','saleIds', v_ids, 'totalProfit', v_total_profit);
end;
$$;

-- ---------- 3) get_raw_table: pastikan v_cols selalu terisi ----------
create or replace function get_raw_table(p_table text)
returns json
language plpgsql
as $$
declare
  v_cols text[];
  v_rows json;
begin
  case upper(p_table)
    when 'PRODUCTS' then
      v_cols := array['id','barcode','name','category','brand','base_unit','reorder_point','active','source'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from products order by id) t;
    when 'PRODUCT_UNITS' then
      v_cols := array['product_id','unit_name','conversion_rate'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from product_units order by product_id, unit_name) t;
    when 'SELLING_PRICES' then
      v_cols := array['id','product_id','unit_name','price','effective_at','active'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from selling_prices order by product_id) t;
    when 'STOCK_LEDGER' then
      v_cols := array['ledger_id','created_at','product_id','ref_type','ref_id','qty_in','qty_out','balance','hpp_avg','inventory_value'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from stock_ledger order by id) t;
    when 'SALES' then
      v_cols := array['id','created_at','product_id','unit_name','qty','qty_base','price_snapshot','total_sale','hpp_base_snapshot','total_hpp','gross_profit'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from sales order by created_at) t;
    when 'PURCHASES' then
      v_cols := array['id','created_at','supplier','invoice','product_id','unit_name','qty','qty_base','total_price','hpp_base_unit','notes'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from purchases order by created_at) t;
    when 'STOCK_OPNAME' then
      v_cols := array['id','created_at','product_id','system_stock','physical_stock','discrepancy','notes'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from stock_opname order by created_at) t;
    when 'EXPENSES' then
      v_cols := array['id','created_at','category','description','amount','payment_method','notes'];
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from expenses order by created_at) t;
    else
      raise exception 'Tabel tidak dikenal: %', p_table;
  end case;
  return json_build_object('columns', to_json(v_cols), 'rows', v_rows);
end;
$$;
