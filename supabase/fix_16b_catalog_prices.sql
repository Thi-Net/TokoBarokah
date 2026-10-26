-- Fix 16b — perbaikan bentuk 'prices' di shop_catalog (harus OBJECT {unit: price},
-- bukan array) supaya frontend membaca harga dengan benar. Menyertakan image_url.
-- Run di Supabase SQL Editor.

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
      'prices', coalesce(pr.prices, '{}'::json),
      'stock', coalesce(l.balance, 0),
      'imageUrl', p.image_url
    ) order by p.category, p.name
  ), '[]'::json)
  from products p
  left join latest l on l.product_id = p.id
  left join (
    select product_id, json_agg(unit_name order by unit_name) as units
    from product_units group by product_id
  ) pu on pu.product_id = p.id
  left join (
    select sp.product_id,
           json_object_agg(sp.unit_name, sp.price) as prices
    from selling_prices sp
    where sp.active = true
    group by sp.product_id
  ) pr on pr.product_id = p.id;
$$;

grant execute on function shop_catalog() to anon;
