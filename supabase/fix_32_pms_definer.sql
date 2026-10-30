-- ============================================================
-- fix_32_pms_definer.sql — Perbaikan "PIN salah" saat konfirmasi bayar bon
-- Penyebab: process_multi_sale tidak security definer, sehingga anon
-- tidak bisa baca app_settings.admin_pin (RLS) -> PIN selalu ditolak.
-- Solusi: jadikan security definer + baca PIN di awal (sebelum loop).
-- Run di Supabase SQL Editor.
-- ============================================================

drop function if exists process_multi_sale(json);
drop function if exists process_multi_sale(json,text,text,text);
create or replace function process_multi_sale(
  p_items json,
  p_payment_method text default 'cash',
  p_creditor_id text default null,
  p_pin text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_conv numeric;
  v_qty_base numeric;
  v_stock numeric;
  v_hpp numeric;
  v_price numeric;
  v_total_sale numeric;
  v_total_hpp numeric;
  v_profit numeric;
  v_total_profit numeric := 0;
  v_grand_total numeric := 0;
  v_ids jsonb := '[]'::jsonb;
  v_id text;
  v_method text := lower(coalesce(p_payment_method, 'cash'));
  v_creditor_id text;
  v_debt_id text;
  v_stored_pin text;
begin
  if v_method not in ('cash','qris','bon') then
    raise exception 'Metode pembayaran tidak dikenal: %', v_method;
  end if;

  if v_method = 'bon' then
    if p_creditor_id is null then
      raise exception 'Pembayaran bon wajib memilih nama peminjam';
    end if;
    select value into v_stored_pin from app_settings where key = 'admin_pin';
    if v_stored_pin is null or p_pin is null or p_pin <> v_stored_pin then
      raise exception 'PIN Admin salah — pembayaran bon butuh verifikasi';
    end if;
    if not exists (select 1 from creditors where id = p_creditor_id) then
      raise exception 'Nama peminjam tidak ditemukan';
    end if;
    v_creditor_id := p_creditor_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items::jsonb)
  loop
    select conversion_rate into v_conv from product_units
    where product_id = v_item->>'productId' and lower(unit_name) = lower(v_item->>'unitName');
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
    where product_id = v_item->>'productId' and lower(unit_name) = lower(v_item->>'unitName') and active = true
    order by effective_at desc limit 1;
    if v_price is null then raise exception 'Harga belum diatur untuk %', v_item->>'productId'; end if;

    v_id := 'SLS-' || to_char(now(),'YYMMDD') || '-' || floor(random()*9000+1000)::int;
    v_total_sale := (v_item->>'qty')::numeric * v_price;
    v_total_hpp := v_qty_base * v_hpp;
    v_profit := v_total_sale - v_total_hpp;

    perform record_stock_ledger(v_item->>'productId', 'SALE', v_id, 0, v_qty_base, 0);

    insert into sales (id, product_id, unit_name, qty, qty_base, price_snapshot, total_sale, hpp_base_snapshot, total_hpp, gross_profit, payment_method)
    values (v_id, v_item->>'productId', v_item->>'unitName', (v_item->>'qty')::numeric, v_qty_base, v_price, v_total_sale, v_hpp, v_total_hpp, v_profit, v_method);

    v_total_profit := v_total_profit + v_profit;
    v_grand_total := v_grand_total + v_total_sale;
    v_ids := v_ids || to_jsonb(v_id);
  end loop;

  -- bon: catat piutang SEKALI per transaksi (satu baris utk semua item)
  if v_method = 'bon' then
    v_debt_id := 'DBT-' || to_char(now(),'YYMMDDHH24MISS');
    insert into debts (id, creditor_id, amount, sale_ids, status)
    values (v_debt_id, v_creditor_id, v_grand_total, v_ids, 'open');
  end if;

  return json_build_object('status','success','saleIds', v_ids, 'totalProfit', v_total_profit,
    'paymentMethod', v_method, 'debtId', v_debt_id);
end;
$$;

grant execute on function process_multi_sale(json,text,text,text) to anon;
