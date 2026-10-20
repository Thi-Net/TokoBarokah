-- ============================================================
-- KelontongPOS: Skema Supabase (Postgres)
-- Porting dari Google Sheets + Apps Script (Kode.gs)
-- Jalankan di Supabase Dashboard > SQL Editor > New query > Run
-- ============================================================

-- ============ TABEL MASTER ============

create table if not exists products (
  id text primary key,                    -- PRD-001
  barcode text default '',
  name text not null,
  category text default '',
  brand text default '',
  base_unit text not null,
  reorder_point numeric default 5,
  active boolean default true,
  source text default 'MIGRATED',
  created_at timestamptz default now()
);

create table if not exists product_units (
  product_id text not null references products(id),
  unit_name text not null,
  conversion_rate numeric not null default 1,
  primary key (product_id, unit_name)
);

create table if not exists selling_prices (
  id text primary key,                    -- PRC-...
  product_id text not null references products(id),
  unit_name text not null,
  price numeric not null,
  effective_at timestamptz default now(),
  active boolean default true
);
create index if not exists idx_prices_active on selling_prices(product_id, unit_name, active);

-- ============ STOCK LEDGER (HPP moving average) ============

create table if not exists stock_ledger (
  id bigserial primary key,
  ledger_id text unique,                  -- LDG-...
  created_at timestamptz default now(),
  product_id text not null references products(id),
  ref_type text not null,                 -- PURCHASE | SALE | OPNAME | INIT
  ref_id text,
  qty_in numeric default 0,
  qty_out numeric default 0,
  balance numeric not null,
  hpp_avg numeric not null default 0,
  inventory_value numeric default 0
);
create index if not exists idx_ledger_product on stock_ledger(product_id, id desc);

-- ============ TRANSAKSI ============

create table if not exists purchases (
  id text primary key,                    -- PUR-...
  created_at timestamptz default now(),
  supplier text not null,
  invoice text,
  product_id text not null references products(id),
  unit_name text not null,
  qty numeric not null,
  qty_base numeric not null,
  total_price numeric not null,
  hpp_base_unit numeric not null,
  notes text default ''
);

create table if not exists sales (
  id text primary key,                    -- SLS-...
  created_at timestamptz default now(),
  product_id text not null references products(id),
  unit_name text not null,
  qty numeric not null,
  qty_base numeric not null,
  price_snapshot numeric not null,
  total_sale numeric not null,
  hpp_base_snapshot numeric not null,
  total_hpp numeric not null,
  gross_profit numeric not null
);
create index if not exists idx_sales_date on sales(created_at desc);

create table if not exists stock_opname (
  id text primary key,                    -- OPN-...
  created_at timestamptz default now(),
  product_id text not null references products(id),
  system_stock numeric,
  physical_stock numeric,
  discrepancy numeric,
  notes text default ''
);

create table if not exists expenses (
  id text primary key,                    -- EXP-...
  created_at timestamptz default now(),
  category text not null,
  description text not null,
  amount numeric not null,
  payment_method text default 'Tunai',
  notes text default ''
);

-- ============ LOGIKA BISNIS (porting dari Apps Script) ============
-- Kunci: cegah stok minus & hitung HPP moving average secara atomik (untuk multi-kasir).

create or replace function record_stock_ledger(
  p_product_id text,
  p_ref_type text,
  p_ref_id text,
  p_qty_in numeric,
  p_qty_out numeric,
  p_incoming_unit_hpp numeric default 0
) returns numeric
language plpgsql
as $$
declare
  v_last_balance numeric;
  v_last_hpp numeric;
  v_new_balance numeric;
  v_new_hpp numeric;
begin
  select balance, hpp_avg into v_last_balance, v_last_hpp
  from stock_ledger where product_id = p_product_id order by id desc limit 1;

  v_last_balance := coalesce(v_last_balance, 0);
  v_last_hpp := coalesce(v_last_hpp, 0);

  v_new_balance := v_last_balance + p_qty_in - p_qty_out;
  if v_new_balance < 0 then
    raise exception 'Stok tidak cukup untuk %: sisa %, diminta %', p_product_id, v_last_balance, p_qty_out;
  end if;

  if p_qty_in > 0 and p_incoming_unit_hpp > 0 then
    v_new_hpp := p_incoming_unit_hpp;
  elsif v_new_balance = 0 then
    v_new_hpp := 0;
  else
    v_new_hpp := v_last_hpp;
  end if;

  insert into stock_ledger (ledger_id, product_id, ref_type, ref_id, qty_in, qty_out, balance, hpp_avg, inventory_value)
  values (
    'LDG-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int,
    p_product_id, p_ref_type, p_ref_id, p_qty_in, p_qty_out,
    v_new_balance, v_new_hpp, v_new_balance * v_new_hpp
  );

  return v_new_hpp;
end;
$$;

-- Pembelian: tambah stok + set HPP base baru
create or replace function process_purchase(
  p_supplier text, p_invoice text, p_product_id text, p_unit_name text,
  p_qty numeric, p_total_price numeric, p_notes text default ''
) returns json
language plpgsql
as $$
declare
  v_conv numeric;
  v_qty_base numeric;
  v_hpp_base numeric;
  v_id text := 'PUR-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
begin
  select conversion_rate into v_conv from product_units
  where product_id = p_product_id and unit_name = p_unit_name;
  if v_conv is null then raise exception 'Satuan % tidak ditemukan untuk %', p_unit_name, p_product_id; end if;

  v_qty_base := p_qty * v_conv;
  v_hpp_base := p_total_price / v_qty_base;

  perform record_stock_ledger(p_product_id, 'PURCHASE', v_id, v_qty_base, 0, v_hpp_base);

  insert into purchases (id, supplier, invoice, product_id, unit_name, qty, qty_base, total_price, hpp_base_unit, notes)
  values (v_id, p_supplier, p_invoice, p_product_id, p_unit_name, p_qty, v_qty_base, p_total_price, v_hpp_base, p_notes);

  return json_build_object('status','success','purchase_id', v_id);
end;
$$;

-- Penjualan multi-item dalam SATU transaksi atomik (semua berhasil atau semua batal)
create or replace function process_multi_sale(p_items json)
returns json
language plpgsql
as $$
declare
  v_item json;
  v_conv numeric;
  v_qty_base numeric;
  v_stock numeric;
  v_hpp numeric;
  v_price numeric;
  v_total_sale numeric;
  v_total_hpp numeric;
  v_profit numeric;
  v_total_profit numeric := 0;
  v_ids json := '[]'::json;
  v_id text;
begin
  for v_item in select * from json_array_elements(p_items)
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
    v_ids := v_ids || to_json(v_id);
  end loop;

  return json_build_object('status','success','saleIds', v_ids, 'totalProfit', v_total_profit);
end;
$$;

-- Stock opname
create or replace function process_stock_opname(
  p_product_id text, p_unit_name text, p_qty numeric, p_notes text default ''
) returns json
language plpgsql
as $$
declare
  v_conv numeric;
  v_physical numeric;
  v_system numeric;
  v_disc numeric;
  v_id text := 'OPN-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
begin
  select conversion_rate into v_conv from product_units
  where product_id = p_product_id and unit_name = p_unit_name;
  if v_conv is null then raise exception 'Satuan % tidak ditemukan', p_unit_name; end if;

  v_physical := p_qty * v_conv;

  select balance into v_system from stock_ledger
  where product_id = p_product_id order by id desc limit 1;
  v_system := coalesce(v_system, 0);

  v_disc := v_physical - v_system;

  if v_disc > 0 then
    perform record_stock_ledger(p_product_id, 'OPNAME', v_id, v_disc, 0, 0);
  elsif v_disc < 0 then
    perform record_stock_ledger(p_product_id, 'OPNAME', v_id, 0, abs(v_disc), 0);
  end if;

  insert into stock_opname (id, product_id, system_stock, physical_stock, discrepancy, notes)
  values (v_id, p_product_id, v_system, v_physical, v_disc, p_notes);

  return json_build_object('status','success','discrepancy', v_disc);
end;
$$;

-- Pengeluaran
create or replace function process_expense(
  p_category text, p_description text, p_amount numeric, p_payment_method text, p_notes text default ''
) returns json
language plpgsql
as $$
begin
  insert into expenses (id, category, description, amount, payment_method, notes)
  values ('EXP-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int,
          p_category, p_description, p_amount, p_payment_method, p_notes);
  return json_build_object('status','success');
end;
$$;

-- Produk baru
create or replace function add_new_product(
  p_name text, p_category text, p_base_unit text, p_hpp numeric, p_selling_price numeric
) returns json
language plpgsql
as $$
declare
  v_num int;
  v_id text;
begin
  select coalesce(max(nullif(regexp_replace(id, '\D', '', 'g'), '')::bigint), 0) + 1 into v_num from products where id like 'PRD-%';
  v_id := 'PRD-' || lpad(v_num::text, 3, '0');

  insert into products (id, name, category, base_unit, active, source) values (v_id, p_name, p_category, p_base_unit, true, 'FRONTEND');
  insert into product_units (product_id, unit_name, conversion_rate) values (v_id, p_base_unit, 1);
  insert into selling_prices (id, product_id, unit_name, price, active)
  values ('PRC-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int, v_id, p_base_unit, p_selling_price, true);

  if p_hpp > 0 then
    perform record_stock_ledger(v_id, 'INIT', 'SETUP', 0, 0, p_hpp);
  end if;

  return json_build_object('status','success','message','Produk baru berhasil ditambahkan!','productId', v_id);
end;
$$;

-- Satuan baru untuk produk existing
create or replace function add_new_unit_to_product(
  p_product_id text, p_unit_name text, p_conversion numeric, p_selling_price numeric
) returns json
language plpgsql
as $$
begin
  insert into product_units (product_id, unit_name, conversion_rate) values (p_product_id, p_unit_name, p_conversion);
  insert into selling_prices (id, product_id, unit_name, price, active)
  values ('PRC-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int, p_product_id, p_unit_name, p_selling_price, true);
  return json_build_object('status','success','message','Satuan baru berhasil disematkan ke produk.');
end;
$$;

-- Update harga jual (nonaktifkan harga lama, buat baru — sama seperti logika Apps Script)
create or replace function update_selling_price(p_product_id text, p_unit_name text, p_new_price numeric)
returns json
language plpgsql
as $$
begin
  update selling_prices set active = false
  where product_id = p_product_id and unit_name = p_unit_name and active = true;
  insert into selling_prices (id, product_id, unit_name, price, active)
  values ('PRC-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int, p_product_id, p_unit_name, p_new_price, true);
  return json_build_object('status','success');
end;
$$;

-- ============ API READ (untuk app) ============

-- Ringkasan dashboard (porting getDashboardSummary)
create or replace function get_dashboard_summary()
returns json
language plpgsql
as $$
declare
  v_result json;
begin
  select json_build_object(
    'finance', json_build_object(
      'sales', coalesce((select sum(total_sale) from sales where created_at::date = current_date), 0),
      'purchases', coalesce((select sum(total_price) from purchases where created_at::date = current_date), 0),
      'grossProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0),
      'netProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0)
                 - coalesce((select sum(amount) from expenses where created_at::date = current_date), 0)
    ),
    'inventoryHealth', (
      select json_build_object(
        'safe', count(*) filter (where stock > 5),
        'low', count(*) filter (where stock > 0 and stock <= 5),
        'critical', count(*) filter (where stock <= 0),
        'items', coalesce((
          select json_agg(json_build_object('name', p.name, 'stock', latest.stock))
          from (
            select distinct on (product_id) product_id, balance as stock
            from stock_ledger order by product_id, id desc
          ) latest
          join products p on p.id = latest.product_id
          where latest.stock <= 5 and p.active = true
          order by latest.stock asc limit 5
        ), '[]'::json)
      )
      from (
        select distinct on (product_id) product_id, balance as stock
        from stock_ledger order by product_id, id desc
      ) s
      join products p on p.id = s.product_id
      where p.active = true
    )
  )
  into v_result;
  return v_result;
end;
$$;

-- Daftar produk aktif + satuan + harga + stok + HPP (porting getActiveProductsList)
create or replace function get_active_products_list()
returns json
language plpgsql
as $$
declare
  v_result json;
begin
  select coalesce(json_agg(
    json_build_object(
      'id', p.id, 'name', p.name, 'category', p.category, 'baseUnit', p.base_unit,
      'stock', coalesce(l.stock, 0),
      'units', pu.units,
      'prices', pr.prices,
      'unitHpp', hp.hpp
    ) order by p.name
  ), '[]'::json)
  into v_result
  from products p
  left join (
    select product_id, balance from (
      select product_id, balance, row_number() over (partition by product_id order by id desc) rn
      from stock_ledger
    ) t where rn = 1
  ) l on l.product_id = p.id
  left join (
    select product_id, json_object_agg(unit_name, conversion_rate) as conv,
           json_object_agg(unit_name, unit_name) as units_raw
    from product_units group by product_id
  ) pu2 on pu2.product_id = p.id,
  lateral (
    select coalesce(
      (select json_agg(unit_name order by unit_name) from product_units where product_id = p.id),
      '[]'::json
    ) as units
  ) pu
  left join (
    select product_id, json_object_agg(unit_name, price) as prices
    from (
      select distinct on (product_id, unit_name) product_id, unit_name, price
      from selling_prices where active = true order by product_id, unit_name, effective_at desc
    ) t group by product_id
  ) pr on pr.product_id = p.id
  left join (
    select l2.product_id, json_object_agg(u.unit_name, l2.hpp_avg * u.conversion_rate) as hpp
    from (
      select product_id, hpp_avg from (
        select product_id, hpp_avg, row_number() over (partition by product_id order by id desc) rn
        from stock_ledger
      ) t where rn = 1
    ) l2
    join product_units u on u.product_id = l2.product_id
    group by l2.product_id
  ) hp on hp.product_id = p.id
  where p.active = true;
  return v_result;
end;
$$;

-- Omzet harian (porting getDailyOmzetData)
create or replace function get_daily_omzet_data(p_date date)
returns json
language plpgsql
as $$
declare
  v_result json;
begin
  select json_build_object(
    'date', p_date,
    'totalOmzet', coalesce(sum(total_sale), 0),
    'totalProfit', coalesce(sum(gross_profit), 0),
    'transactions', coalesce(json_agg(json_build_object(
      'id', id, 'time', to_char(created_at, 'HH24:MI:SS'),
      'product', coalesce((select name from products where id = s.product_id), s.product_id),
      'unit', s.unit_name, 'qty', s.qty, 'price', s.price_snapshot, 'total', s.total_sale
    ) order by created_at), '[]'::json)
  )
  into v_result
  from sales s
  where created_at::date = p_date;
  return v_result;
end;
$$;

-- Laporan keuangan per periode (porting getFilteredFinancialReport)
create or replace function get_filtered_financial_report(p_period text, p_date date)
returns json
language plpgsql
as $$
declare
  v_start date;
  v_end date;
  v_result json;
begin
  v_start := p_date;
  v_end := p_date;
  if p_period = 'mingguan' then
    v_start := p_date - ((extract(isodow from p_date)::int) - 1);
    v_end := v_start + 6;
  elsif p_period = 'bulanan' then
    v_start := date_trunc('month', p_date)::date;
    v_end := (date_trunc('month', p_date) + interval '1 month - 1 day')::date;
  end if;

  select json_build_object(
    'periodName', upper(p_period),
    'dateRange', to_char(v_start,'DD/MM/YYYY') || ' s.d. ' || to_char(v_end,'DD/MM/YYYY'),
    'sales', coalesce((select sum(total_sale) from sales where created_at::date between v_start and v_end), 0),
    'hpp', coalesce((select sum(total_hpp) from sales where created_at::date between v_start and v_end), 0),
    'grossProfit', coalesce((select sum(gross_profit) from sales where created_at::date between v_start and v_end), 0),
    'expenses', coalesce((select sum(amount) from expenses where created_at::date between v_start and v_end), 0),
    'netProfit', coalesce((select sum(gross_profit) from sales where created_at::date between v_start and v_end), 0)
               - coalesce((select sum(amount) from expenses where created_at::date between v_start and v_end), 0),
    'purchases', coalesce((select sum(total_price) from purchases where created_at::date between v_start and v_end), 0),
    'rawSales', coalesce((select json_agg(json_build_array(id, to_char(created_at,'DD/MM/YY HH24:MI'),
      coalesce((select name from products where id = s.product_id), s.product_id), s.unit_name, s.qty, s.total_sale, s.gross_profit)
      order by created_at) from sales s where created_at::date between v_start and v_end), '[]'::json),
    'rawPurchases', coalesce((select json_agg(json_build_array(id, to_char(created_at,'DD/MM/YY HH24:MI'), supplier, invoice,
      coalesce((select name from products where id = pu.product_id), pu.product_id), pu.unit_name, pu.qty, pu.total_price)
      order by created_at) from purchases pu where created_at::date between v_start and v_end), '[]'::json),
    'rawExpenses', coalesce((select json_agg(json_build_array(id, to_char(created_at,'DD/MM/YY HH24:MI'), category, description, amount, payment_method)
      order by created_at) from expenses where created_at::date between v_start and v_end), '[]'::json)
  )
  into v_result;
  return v_result;
end;
$$;

-- Stock ledger terakhir 50 (porting getStockLedgerData)
create or replace function get_stock_ledger_data()
returns json
language plpgsql
as $$
declare
  v_result json;
begin
  select coalesce(json_agg(json_build_object(
    'time', to_char(created_at,'DD/MM/YYYY HH24:MI:SS'),
    'productId', product_id, 'refType', ref_type,
    'qtyIn', qty_in, 'qtyOut', qty_out, 'balance', balance, 'hppAvg', hpp_avg
  ) order by id desc), '[]'::json)
  into v_result
  from (select * from stock_ledger order by id desc limit 50) t;
  return v_result;
end;
$$;

-- Cek produk exists (porting checkProductExists)
create or replace function check_product_exists(p_name text, p_unit text)
returns json
language plpgsql
as $$
declare
  v_prod record;
  v_same_unit boolean := false;
begin
  select * into v_prod from products where lower(name) = lower(p_name) limit 1;
  if not found then return json_build_object('exists', false); end if;

  select exists(
    select 1 from product_units where product_id = v_prod.id and lower(unit_name) = lower(p_unit)
  ) into v_same_unit;

  return json_build_object(
    'exists', true, 'sameUnit', v_same_unit,
    'product', json_build_object('id', v_prod.id, 'barcode', v_prod.barcode, 'name', v_prod.name,
      'category', v_prod.category, 'brand', v_prod.brand, 'baseUnit', v_prod.base_unit)
  );
end;
$$;

-- ============ EKSPOR DATA UNTUK APP (raw sheet pengganti) ============

-- Data mentah ala "sheet" agar fitur Database Raw tetap bekerja
create or replace function get_raw_table(p_table text)
returns json
language plpgsql
as $$
declare
  v_cols text[] ;
  v_rows json;
begin
  case upper(p_table)
    when 'PRODUCTS' then
      select array['id','barcode','name','category','brand','base_unit','reorder_point','active','source'] into v_cols;
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from products order by id) t;
    when 'PRODUCT_UNITS' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from product_units order by product_id) t;
    when 'SELLING_PRICES' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from selling_prices order by product_id) t;
    when 'STOCK_LEDGER' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from stock_ledger order by id) t;
    when 'SALES' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from sales order by created_at) t;
    when 'PURCHASES' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from purchases order by created_at) t;
    when 'STOCK_OPNAME' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from stock_opname order by created_at) t;
    when 'EXPENSES' then
      select coalesce(json_agg(row_to_json(t)), '[]'::json) into v_rows from (select * from expenses order by created_at) t;
    else raise exception 'Tabel tidak dikenal: %', p_table;
  end case;
  return json_build_object('columns', to_json(v_cols), 'rows', v_rows);
end;
$$;

-- ============ EKPOSISI RPC UNTUK ANON (app) ============
-- App memanggil lewat PostgREST RPC. Aktifkan akses untuk role anon.

grant usage on schema public to anon;
grant execute on function
  process_purchase(text,text,text,text,numeric,numeric,text),
  process_multi_sale(json),
  process_stock_opname(text,text,numeric,text),
  process_expense(text,text,numeric,text,text),
  add_new_product(text,text,text,numeric,numeric),
  add_new_unit_to_product(text,text,numeric,numeric),
  update_selling_price(text,text,numeric),
  get_dashboard_summary(),
  get_active_products_list(),
  get_daily_omzet_data(date),
  get_filtered_financial_report(text,date),
  get_stock_ledger_data(),
  check_product_exists(text,text),
  get_raw_table(text)
to anon;

-- Fungsi lain (record_stock_ledger) tidak diekspos
revoke execute on function record_stock_ledger(text,text,text,numeric,numeric,numeric) from anon;
