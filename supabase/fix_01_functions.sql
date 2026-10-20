-- ============================================================
-- KelontongPOS: Fix fungsi yang error (jalankan di SQL Editor)
-- ============================================================

-- 1) get_active_products_list
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
      'id', p.id, 'name', p.name, 'category', p.category, 'baseUnit', p.base_unit,
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

-- 2) get_dashboard_summary
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
  )
  select json_build_object(
    'finance', json_build_object(
      'sales', coalesce((select sum(total_sale) from sales where created_at::date = current_date), 0),
      'purchases', coalesce((select sum(total_price) from purchases where created_at::date = current_date), 0),
      'grossProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0),
      'netProfit', coalesce((select sum(gross_profit) from sales where created_at::date = current_date), 0)
                 - coalesce((select sum(amount) from expenses where created_at::date = current_date), 0)
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
