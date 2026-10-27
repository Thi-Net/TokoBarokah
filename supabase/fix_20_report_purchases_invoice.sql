-- fix_20_report_purchases_invoice.sql — kolom 'invoice' hilang di sheet Pembelian Excel.
-- Versi get_filtered_financial_report yang live di DB mengirim rawPurchases 7 kolom
-- (ID, Waktu, Produk, Satuan, Qty, Total, Supplier) TANPA invoice.
-- Fix ini menggantinya: rawPurchases 8 kolom
-- ID, Waktu, Supplier, Invoice, Produk, Satuan, Qty, Total Harga.
-- rawSales & rawExpenses tidak diubah (sudah benar).
-- Header frontend disesuaikan di rilis web yang sama.
-- Jalankan di Supabase SQL Editor, lalu verifikasi via curl.

drop function if exists get_filtered_financial_report(text, date);

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
  if p_type = 'daily' then
    v_start := v_date; v_end := v_date;
  elsif p_type = 'monthly' then
    v_start := date_trunc('month', v_date)::date;
    v_end := (date_trunc('month', v_date) + interval '1 month - 1 day')::date;
  elsif p_type = 'yearly' then
    v_start := date_trunc('year', v_date)::date;
    v_end := (date_trunc('year', v_date) + interval '1 year - 1 day')::date;
  else
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
