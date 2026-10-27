-- fix_21_laporan_periode.sql — perbaikan lanjutan laporan keuangan:
-- 1) p_type menerima istilah frontend: harian / mingguan / bulanan / tahunan
--    (versi fix_20b hanya kenal daily/monthly/yearly → mingguan & bulanan
--    jatuh ke cabang else = sama seperti harian. Ini bug "data tidak berubah".)
-- 2) Minggu pakai ISO week (Senin mulai), seperti versi lama yang benar.
-- 3) Shape data dipertahankan: rawSales 9 kolom
--    [id, waktu, produk, satuan, qty, harga_satuan, omzet, hpp, laba_kotor],
--    rawPurchases 8 kolom [id, waktu, supplier, invoice, produk, satuan, qty, total].
-- Jalankan di Supabase SQL Editor.

drop function if exists get_filtered_financial_report(date, text);
drop function if exists get_filtered_financial_report(text, date);
drop function if exists get_filtered_financial_report(date);
drop function if exists get_filtered_financial_report(text);

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
  if p_type = 'mingguan' then
    v_start := v_date - ((extract(isodow from v_date)::int) - 1);
    v_end := v_start + 6;
  elsif p_type = 'bulanan' then
    v_start := date_trunc('month', v_date)::date;
    v_end := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;
  elsif p_type = 'tahunan' then
    v_start := date_trunc('year', v_date)::date;
    v_end := (date_trunc('year', v_date) + interval '1 year - 1 day')::date;
  else -- harian / daily (default)
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
    'dateRange', to_char(v_start,'DD/MM/YYYY') || ' s.d. ' || to_char(v_end,'DD/MM/YYYY'),
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

grant execute on function get_filtered_financial_report(text, date) to anon;
