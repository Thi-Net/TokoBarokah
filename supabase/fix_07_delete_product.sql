-- ============================================================
-- KelontongPOS Fix 07: hapus produk (ikon sampah di tab Produk)
-- Hapus produk + semua data terkait (unit, harga, ledger, opname)
-- ============================================================

create or replace function delete_product(p_product_id text)
returns json
language plpgsql
security definer
as $$
declare
  v_name text;
begin
  select name into v_name from products where id = p_product_id;
  if v_name is null then
    return json_build_object('status','error','message','Produk tidak ditemukan: ' || p_product_id);
  end if;

  delete from selling_prices where product_id = p_product_id;
  delete from stock_ledger    where product_id = p_product_id;
  delete from stock_opname    where product_id = p_product_id;
  delete from product_units   where product_id = p_product_id;
  delete from products        where id = p_product_id;

  return json_build_object('status','success','message','Produk "' || v_name || '" beserta datanya dihapus.');
end;
$$;

grant execute on function delete_product(text) to anon;
