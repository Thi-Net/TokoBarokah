-- ============================================================
-- KelontongPOS Fix 08: barcode sudah terdaftar -> alur tambah satuan
-- Backend tidak berubah: UI web sudah resolve lewat
-- get_active_products_list + add_new_unit_to_product.
-- Fix ini hanya mengamankan add_new_unit_to_product dari
-- duplikat satuan (unique guard) supaya double-submit tidak error 23505 mentah.
-- ============================================================

drop function if exists add_new_unit_to_product(text, text, numeric, numeric);

create or replace function add_new_unit_to_product(
  p_product_id text, p_unit_name text, p_conversion numeric, p_selling_price numeric
) returns json
language plpgsql
as $$
declare
  v_exists boolean;
begin
  select exists(
    select 1 from product_units
    where product_id = p_product_id and lower(unit_name) = lower(trim(p_unit_name))
  ) into v_exists;
  if v_exists then
    return json_build_object('status','exists','message','Satuan "' || p_unit_name || '" sudah ada untuk produk ini.');
  end if;

  insert into product_units (product_id, unit_name, conversion_rate)
  values (p_product_id, trim(p_unit_name), p_conversion);
  insert into selling_prices (id, product_id, unit_name, price, active)
  values ('PRC-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int, p_product_id, trim(p_unit_name), p_selling_price, true);
  return json_build_object('status','success','message','Satuan baru berhasil disematkan ke produk.');
end;
$$;
