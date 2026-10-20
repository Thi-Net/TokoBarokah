-- ============================================================
-- KelontongPOS: 放开 anon 对数据表的必要权限（迁移 + Database Raw 需要）
-- 原则：给 anon 增/改，不给 delete；更新仅限少量"可编辑"表。
-- 迁移完成后如需收紧，可只保留前两段（schema/表 usage）。
-- ============================================================

grant usage on schema public to anon;

-- 所有业务表：允许 INSERT 与 SELECT（迁移写入 + app 读取）
grant insert, select on
  products, product_units, selling_prices, stock_ledger,
  sales, purchases, stock_opname, expenses
to anon;

-- Database Raw 的"编辑保存"功能只覆盖两张主数据表 → 允许 UPDATE
grant update on products, product_units to anon;

-- 序列（bigint 主键自增）需要使用权限
grant usage, select on all sequences in schema public to anon;

-- RLS 策略：anon 可读写上述表（无 delete）
alter table products enable row level security;
alter table product_units enable row level security;
alter table selling_prices enable row level security;
alter table stock_ledger enable row level security;
alter table sales enable row level security;
alter table purchases enable row level security;
alter table stock_opname enable row level security;
alter table expenses enable row level security;

drop policy if exists anon_insert_products on products;
create policy anon_insert_products on products for insert to anon with check (true);
drop policy if exists anon_select_products on products;
create policy anon_select_products on products for select to anon using (true);
drop policy if exists anon_update_products on products;
create policy anon_update_products on products for update to anon using (true) with check (true);

drop policy if exists anon_insert_product_units on product_units;
create policy anon_insert_product_units on product_units for insert to anon with check (true);
drop policy if exists anon_select_product_units on product_units;
create policy anon_select_product_units on product_units for select to anon using (true);
drop policy if exists anon_update_product_units on product_units;
create policy anon_update_product_units on product_units for update to anon using (true) with check (true);

drop policy if exists anon_insert_selling_prices on selling_prices;
create policy anon_insert_selling_prices on selling_prices for insert to anon with check (true);
drop policy if exists anon_select_selling_prices on selling_prices;
create policy anon_select_selling_prices on selling_prices for select to anon using (true);

drop policy if exists anon_insert_stock_ledger on stock_ledger;
create policy anon_insert_stock_ledger on stock_ledger for insert to anon with check (true);
drop policy if exists anon_select_stock_ledger on stock_ledger;
create policy anon_select_stock_ledger on stock_ledger for select to anon using (true);

drop policy if exists anon_insert_sales on sales;
create policy anon_insert_sales on sales for insert to anon with check (true);
drop policy if exists anon_select_sales on sales;
create policy anon_select_sales on sales for select to anon using (true);

drop policy if exists anon_insert_purchases on purchases;
create policy anon_insert_purchases on purchases for insert to anon with check (true);
drop policy if exists anon_select_purchases on purchases;
create policy anon_select_purchases on purchases for select to anon using (true);

drop policy if exists anon_insert_stock_opname on stock_opname;
create policy anon_insert_stock_opname on stock_opname for insert to anon with check (true);
drop policy if exists anon_select_stock_opname on stock_opname;
create policy anon_select_stock_opname on stock_opname for select to anon using (true);

drop policy if exists anon_insert_expenses on expenses;
create policy anon_insert_expenses on expenses for insert to anon with check (true);
drop policy if exists anon_select_expenses on expenses;
create policy anon_select_expenses on expenses for select to anon using (true);
