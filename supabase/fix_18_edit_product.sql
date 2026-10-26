-- ============================================================
-- Fix 18 — Edit produk dari POS (nama, id, barcode, satuan)
-- RPC admin (PIN check, security definer):
--   admin_edit_product(p_pin, p_product_id, p_new_id, p_name, p_barcode,
--                      p_units json)  -- [{action:'rename',from,to},{action:'add',unit,price},{action:'remove',unit}]
-- Edit ID: update cascade manual ke semua tabel FK.
-- Run di Supabase SQL Editor.
-- ============================================================

create or replace function admin_edit_product(
  p_pin text,
  p_product_id text,
  p_new_id text,
  p_name text,
  p_barcode text,
  p_units json default '[]'::json
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_id text := nullif(trim(coalesce(p_new_id,'')), '');
  v_name text := nullif(trim(coalesce(p_name,'')), '');
  v_barcode text := coalesce(p_barcode, '');
  v_cur_id text := trim(p_product_id);
  v_unit json;
  v_from text; v_to text; v_u text; v_price numeric;
  v_used int;
begin
  -- Verifikasi PIN: simpan PIN di tabel app_settings (dibuat bila belum ada)
  if not exists (select 1 from information_schema.tables where table_name='app_settings') then
    create table if not exists app_settings (key text primary key, value text not null);
  end if;
  if not exists (select 1 from app_settings where key='admin_pin') then
    insert into app_settings(key, value) values ('admin_pin', '251104')
    on conflict (key) do nothing;
  end if;
  if p_pin is distinct from (select value from app_settings where key='admin_pin') then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;

  if v_cur_id = '' then
    return json_build_object('ok', false, 'message', 'Product ID lama wajib.');
  end if;
  if not exists (select 1 from products where id = v_cur_id) then
    return json_build_object('ok', false, 'message', 'Produk tidak ditemukan: ' || v_cur_id);
  end if;

  -- ==== EDIT ID ====
  if v_new_id is not null and v_new_id <> v_cur_id then
    if exists (select 1 from products where id = v_new_id) then
      return json_build_object('ok', false, 'message', 'Product ID baru sudah dipakai: ' || v_new_id);
    end if;
    -- urutan aman: tabel anak tanpa cascade on delete, kita rename manual
    update product_units  set product_id = v_new_id where product_id = v_cur_id;
    update selling_prices set product_id = v_new_id where product_id = v_cur_id;
    update stock_ledger   set product_id = v_new_id where product_id = v_cur_id;
    update purchases      set product_id = v_new_id where product_id = v_cur_id;
    update sales          set product_id = v_new_id where product_id = v_cur_id;
    update stock_opname   set product_id = v_new_id where product_id = v_cur_id;
    update order_items    set product_id = v_new_id where product_id = v_cur_id;
    update products       set id = v_new_id where id = v_cur_id;
    v_cur_id := v_new_id;
  end if;

  -- ==== EDIT NAMA & BARCODE ====
  if v_name is not null or p_barcode is not null then
    update products set
      name = coalesce(v_name, name),
      barcode = coalesce(v_barcode, barcode)
    where id = v_cur_id;
  end if;

  -- ==== SATUAN ====
  for v_unit in select * from json_array_elements(coalesce(p_units, '[]'::json)) loop
    case (v_unit->>'action')
    when 'rename' then
      v_from := nullif(trim(coalesce(v_unit->>'from','')), '');
      v_to := nullif(trim(coalesce(v_unit->>'to','')), '');
      if v_from is null or v_to is null then
        return json_build_object('ok', false, 'message', 'Rename satuan: from/to wajib.');
      end if;
      if exists (select 1 from product_units where product_id = v_cur_id and unit_name = v_to) then
        return json_build_object('ok', false, 'message', 'Satuan "' || v_to || '" sudah ada.');
      end if;
      -- cek pemakaian di transaksi (order_items, sales, purchases)
      select count(*) into v_used from order_items where product_id = v_cur_id and unit_name = v_from;
      select count(*) + v_used into v_used from sales where product_id = v_cur_id and unit_name = v_from;
      select count(*) + v_used into v_used from purchases where product_id = v_cur_id and unit_name = v_from;
      if v_used > 0 then
        -- tetap boleh rename transaksi lama ikut (agar laporan konsisten)
        update order_items  set unit_name = v_to where product_id = v_cur_id and unit_name = v_from;
        update sales        set unit_name = v_to where product_id = v_cur_id and unit_name = v_from;
        update purchases    set unit_name = v_to where product_id = v_cur_id and unit_name = v_from;
      end if;
      update product_units   set unit_name = v_to where product_id = v_cur_id and unit_name = v_from;
      update selling_prices  set unit_name = v_to where product_id = v_cur_id and unit_name = v_from and active = true;
    when 'add' then
      v_u := nullif(trim(coalesce(v_unit->>'unit','')), '');
      v_price := nullif(v_unit->>'price','')::numeric;
      if v_u is null then
        return json_build_object('ok', false, 'message', 'Tambah satuan: nama satuan wajib.');
      end if;
      if exists (select 1 from product_units where product_id = v_cur_id and unit_name = v_u) then
        return json_build_object('ok', false, 'message', 'Satuan "' || v_u || '" sudah ada.');
      end if;
      insert into product_units (product_id, unit_name, conversion_rate)
      values (v_cur_id, v_u, coalesce((v_unit->>'conversion')::numeric, 1));
      if v_price is not null and v_price > 0 then
        insert into selling_prices (id, product_id, unit_name, price)
        values ('PRC-' || to_char(now() at time zone 'Asia/Jakarta','YYMMDDHH24MISS') || '-' ||
                lpad((abs(hashtext(v_cur_id || v_u || extract(epoch from now())::text)) % 9000 + 1000)::text, 4, '0'),
                v_cur_id, v_u, v_price);
      end if;
    when 'remove' then
      v_u := nullif(trim(coalesce(v_unit->>'unit','')), '');
      if v_u is null then
        return json_build_object('ok', false, 'message', 'Hapus satuan: nama satuan wajib.');
      end if;
      -- satuan terakhir tidak boleh dihapus
      if (select count(*) from product_units where product_id = v_cur_id) <= 1 then
        return json_build_object('ok', false, 'message', 'Minimal 1 satuan harus tersisa.');
      end if;
      -- tidak boleh hapus jika unit = base_unit
      if v_u = (select base_unit from products where id = v_cur_id) then
        return json_build_object('ok', false, 'message', 'Satuan "' || v_u || '" adalah satuan dasar, tidak bisa dihapus.');
      end if;
      -- cek pemakaian transaksi: tolak agar data historis konsisten
      select count(*) into v_used from order_items where product_id = v_cur_id and unit_name = v_u;
      select count(*) + v_used into v_used from sales where product_id = v_cur_id and unit_name = v_u;
      select count(*) + v_used into v_used from purchases where product_id = v_cur_id and unit_name = v_u;
      if v_used > 0 then
        return json_build_object('ok', false, 'message',
          'Satuan "' || v_u || '" sudah dipakai di ' || v_used || ' transaksi — tidak bisa dihapus. Gunakan Rename saja.');
      end if;
      delete from selling_prices where product_id = v_cur_id and unit_name = v_u;
      delete from product_units  where product_id = v_cur_id and unit_name = v_u;
    else
      return json_build_object('ok', false, 'message', 'Aksi satuan tidak dikenal: ' || coalesce(v_unit->>'action','?'));
    end case;
  end loop;

  return json_build_object('ok', true, 'message', 'Perubahan tersimpan.', 'productId', v_cur_id);
end;
$$;

grant execute on function admin_edit_product(text,text,text,text,text,json) to anon;
