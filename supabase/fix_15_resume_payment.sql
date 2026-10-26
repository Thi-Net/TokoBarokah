-- ============================================================
-- KelontongPOS Marketplace: Fix 15 — lanjutkan pembayaran + expired otomatis
-- 1) shop_my_orders ikut mengirim data payment Mayar (link + expiry + status)
-- 2) shop_resume_payment: customer lanjut bayar order pending
--    - ambil link Mayar yang ada, atau buat tagihan baru bila belum ada
--    - jika tagihan sudah lewat masa berlaku (24 jam Mayar), order otomatis
--      dibatalkan (status cancelled + payment expired)
-- Catatan: pembuatan tagihan BARU tetap lewat Edge Function mayar-create
-- (API key tidak boleh di RPC). RPC ini hanya membaca/menandai.
-- Jalankan di Supabase SQL Editor.
-- ============================================================

-- my orders: sertakan info payment untuk melanjutkan pembayaran
create or replace function shop_my_orders(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_orders json;
  v_items json;
  v_pays json;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select coalesce(json_agg(o order by o.created_at desc), '[]'::json) into v_orders
  from orders o where o.customer_id = v_cid;
  select coalesce(json_agg(oi), '[]'::json) into v_items
  from order_items oi join orders o2 on o2.id = oi.order_id
  where o2.customer_id = v_cid;
  select coalesce(json_agg(p), '[]'::json) into v_pays
  from payments p join orders o3 on o3.id = p.order_id
  where o3.customer_id = v_cid
    and p.provider = 'mayar';
  return json_build_object('ok', true, 'orders', v_orders, 'items', v_items, 'payments', v_pays);
end;
$$;

-- lanjutkan pembayaran order pending:
-- - kalau ada tagihan Mayar aktif (belum lewat 24 jam) -> kembalikan linknya
-- - kalau tagihan lewat masa berlaku -> payment expired + order cancelled
-- - kalau belum ada tagihan -> kembalikan sinyal 'need_create' (frontend
--   memanggil Edge Function mayar-create seperti checkout biasa)
create or replace function shop_resume_payment(p_token text, p_order_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cid text := _shop_auth(p_token);
  v_order record;
  v_pay record;
  v_age interval;
begin
  if v_cid is null then return json_build_object('ok', false, 'message', 'Sesi tidak valid.'); end if;
  select * into v_order from orders where id = p_order_id and customer_id = v_cid;
  if not found then return json_build_object('ok', false, 'message', 'Order tidak ditemukan.'); end if;
  if v_order.status <> 'pending' then
    return json_build_object('ok', false, 'message', 'Order tidak dalam status menunggu pembayaran.');
  end if;
  if v_order.payment_method = 'cod' then
    return json_build_object('ok', false, 'message', 'Pesanan COD tidak perlu pembayaran online.');
  end if;

  select * into v_pay from payments
  where order_id = p_order_id and provider = 'mayar'
  order by created_at desc limit 1;

  if found then
    v_age := now() - v_pay.created_at;
    if v_age >= interval '1 hour' then
      -- lewat masa berlaku tagihan Mayar (expiredAt = created_at + 1 jam, semua metode)
      update payments set status = 'expired' where id = v_pay.id;
      update orders set status = 'cancelled', updated_at = now() where id = p_order_id;
      return json_build_object('ok', false, 'expired', true,
        'message', 'Waktu pembayaran habis (1 jam). Pesanan dibatalkan otomatis. Silakan buat pesanan baru.');
    end if;
    -- tagihan masih aktif: lanjutkan dengan link yang sama
    if v_pay.status = 'initiated' then
      update orders set payment_method = coalesce(nullif(v_pay.method,''), v_order.payment_method), updated_at = now() where id = p_order_id;
    end if;
    return json_build_object('ok', true, 'resume', true,
      'paymentId', v_pay.id, 'link', v_pay.mayar_link, 'amount', v_order.total,
      'method', v_pay.method, 'expires_in_minutes',
      floor(extract(epoch from (interval '1 hour' - v_age)) / 60));
  end if;

  -- belum ada tagihan Mayar: frontend memanggil mayar-create
  return json_build_object('ok', true, 'resume', false, 'need_create', true,
    'amount', v_order.total);
end;
$$;

grant execute on function
  shop_my_orders(text),
  shop_resume_payment(text,text)
to anon;
