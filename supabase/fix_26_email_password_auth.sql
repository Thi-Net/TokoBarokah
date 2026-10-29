-- fix_26_email_password_auth.sql — login toko online ganti EMAIL + PASSWORD (opsi B).
-- Phone-based login ditinggalkan. Token tetap TOK-CUS-<id> agar _shop_auth & order flow tak berubah.
-- Password di-hash sha256(salt || password) dengan salt per-customer (kolom pass_salt).
-- Catatan: sha256+salt memadai untuk toko UMKM; bukan bcrypt (tidak tersedia di Supabase SQL tanpa extension pgcrypto).
-- Jalankan di Supabase SQL Editor.

begin;

-- 1. Tambah kolom email & password ke customers (buat tabel bila belum ada bentuk ini)
alter table customers add column if not exists email text unique;
alter table customers add column if not exists pass_hash text;
alter table customers add column if not exists pass_salt text;

-- 2. Hash helper (pgcrypto)
create extension if not exists pgcrypto;

create or replace function _shop_pass_hash(p_salt text, p_pass text)
returns text language sql immutable as $$
  select encode(sha256((p_salt || p_pass)::bytea), 'hex');  -- sha256() built-in Postgres 11+, tanpa pgcrypto
$$;

-- 3. Daftar / set password (upsert customer by email)
create or replace function shop_register_email(p_email text, p_password text, p_name text default '')
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(btrim(p_email));
  v_id text;
  v_salt text;
begin
  if v_email not like '%_@_%._%' then
    return json_build_object('ok', false, 'message', 'Email tidak valid.');
  end if;
  if length(coalesce(p_password,'')) < 6 then
    return json_build_object('ok', false, 'message', 'Password minimal 6 karakter.');
  end if;
  select id into v_id from customers where email = v_email;
  if v_id is null then
    v_id := 'CUS-' || to_char(now() at time zone 'Asia/Jakarta','YYMMDD') || '-' ||
      lpad((floor(random()*900)+100)::text, 3, '0');
    -- pastikan unik
    while exists(select 1 from customers where id = v_id) loop
      v_id := 'CUS-' || to_char(now() at time zone 'Asia/Jakarta','YYMMDD') || '-' ||
        lpad((floor(random()*900)+100)::text, 3, '0');
    end loop;
    insert into customers (id, phone, name, email) values (v_id, 'EMAIL-' || v_id, p_name, v_email);
  end if;
  v_salt := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');  -- 64 hex chars
  update customers set pass_salt = v_salt, pass_hash = _shop_pass_hash(v_salt, p_password),
    name = case when coalesce(p_name,'') <> '' then p_name else name end
  where id = v_id;
  return json_build_object('ok', true, 'customerId', v_id, 'name',
    (select name from customers where id = v_id), 'token', 'TOK-' || v_id);
end;
$$;

-- 4. Login email + password
create or replace function shop_login_email(p_email text, p_password text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(btrim(p_email));
  v_cust record;
begin
  select * into v_cust from customers where email = v_email;
  if not found or v_cust.pass_hash is null then
    return json_build_object('ok', false, 'message', 'Email belum terdaftar atau password belum diset.');
  end if;
  if v_cust.pass_hash <> _shop_pass_hash(v_cust.pass_salt, p_password) then
    return json_build_object('ok', false, 'message', 'Email atau password salah.');
  end if;
  return json_build_object('ok', true, 'customerId', v_cust.id, 'name', v_cust.name, 'token', 'TOK-' || v_cust.id);
end;
$$;

grant execute on function shop_register_email(text, text, text) to anon;
grant execute on function shop_login_email(text, text) to anon;

commit;
