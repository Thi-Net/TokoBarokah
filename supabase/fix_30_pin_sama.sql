-- ============================================================
-- fix_30_pin_sama.sql — Samakan PIN admin ke '1234' di SEMUA fungsi
-- app_settings.admin_pin = '1234' + fungsi marketplace (hard-coded)
-- ikut baca dari app_settings agar konsisten & bisa di-rotate nanti.
-- Run di Supabase SQL Editor.
-- ============================================================

-- 1) PIN tersimpan = 1234
insert into app_settings (key, value) values ('admin_pin', '1234')
on conflict (key) do update set value = excluded.value;

-- 2) shop_admin_orders & shop_admin_set_status: baca dari app_settings
create or replace function shop_admin_orders(p_admin_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_orders json; v_items json; v_custs json;
begin
  if coalesce(p_admin_pin,'') <> (select value from app_settings where key = 'admin_pin') then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;
  select coalesce(json_agg(o order by o.created_at desc), '[]'::json) into v_orders from orders o;
  select coalesce(json_agg(oi), '[]'::json) into v_items from order_items oi;
  select coalesce(json_agg(c order by c.created_at desc), '[]'::json) into v_custs from customers c;
  return json_build_object('ok', true, 'orders', v_orders, 'items', v_items, 'customers', v_custs);
end;
$$;

create or replace function shop_admin_set_status(p_admin_pin text, p_order_id text, p_status text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_admin_pin,'') <> (select value from app_settings where key = 'admin_pin') then
    return json_build_object('ok', false, 'message', 'PIN admin salah.');
  end if;
  -- status terkini fix_12: 'shipping' (bukan 'shipped')
  if p_status not in ('pending','paid','processing','ready','shipping','completed','cancelled') then
    return json_build_object('ok', false, 'message', 'Status tidak valid.');
  end if;
  update orders set status = p_status, updated_at = now() where id = p_order_id;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;
  return json_build_object('ok', true, 'message', 'Status order ' || p_order_id || ' -> ' || p_status);
end;
$$;

-- 3) grant (idempoten)
grant execute on function shop_admin_orders(text) to anon;
grant execute on function shop_admin_set_status(text,text,text) to anon;
