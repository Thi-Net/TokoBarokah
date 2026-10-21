-- ============================================================
-- KelontongPOS Fix 06: barcode di add_new_product
-- ============================================================
drop function if exists add_new_product(text, text, text, numeric, numeric);
drop function if exists add_new_product(text, text, text, numeric, numeric, text);

create or replace function add_new_product(
  p_name text, p_category text, p_base_unit text, p_hpp numeric, p_selling_price numeric, p_barcode text default null
) returns json
language plpgsql
as $$
declare
  v_num int;
  v_id text;
begin
  select coalesce(max(nullif(regexp_replace(id, '\D', '', 'g'), '')::bigint), 0) + 1 into v_num from products where id like 'PRD-%';
  v_id := 'PRD-' || lpad(v_num::text, 3, '0');

  insert into products (id, name, barcode, category, base_unit, active, source)
  values (v_id, p_name, nullif(trim(coalesce(p_barcode, '')), ''), p_category, p_base_unit, true, 'FRONTEND');
  insert into product_units (product_id, unit_name, conversion_rate) values (v_id, p_base_unit, 1);
  insert into selling_prices (id, product_id, unit_name, price, active)
  values ('PRC-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int, v_id, p_base_unit, p_selling_price, true);

  if p_hpp > 0 then
    perform record_stock_ledger(v_id, 'INIT', 'SETUP', 0, 0, p_hpp);
  end if;

  return json_build_object('status','success','message','Produk baru berhasil ditambahkan!','productId', v_id);
end;
$$;
