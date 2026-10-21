-- ============================================================
-- KelontongPOS Fix Batch 2 (21 Okt 2026)
-- barcode ikut di get_active_products_list (untuk scanner & kolom barcode)
-- ============================================================

create or replace function get_active_products_list()
returns json
language plpgsql
as $$
declare
  v_result json;
begin
  with latest as (
    select product_id, balance, hpp_avg from (
      select product_id, balance, hpp_avg,
             row_number() over (partition by product_id order by id desc) rn
      from stock_ledger
    ) t where rn = 1
  )
  select coalesce(json_agg(
    json_build_object(
      'id', p.id, 'barcode', coalesce(p.barcode, ''), 'name', p.name, 'category', p.category, 'baseUnit', p.base_unit,
      'stock', coalesce(l.balance, 0),
      'units', pu.units,
      'prices', pr.prices,
      'unitHpp', hp.hpp
    ) order by p.name
  ), '[]'::json)
  into v_result
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
      order by product_id, unit_name, effective_at desc
    ) t group by product_id
  ) pr on pr.product_id = p.id
  left join (
    select u.product_id,
           json_object_agg(u.unit_name, coalesce(l.hpp_avg, 0) * u.conversion_rate) as hpp
    from product_units u
    left join latest l on l.product_id = u.product_id
    group by u.product_id
  ) hp on hp.product_id = p.id
  where p.active = true;
  return v_result;
end;
$$;
