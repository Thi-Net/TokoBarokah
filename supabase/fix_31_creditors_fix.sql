-- ============================================================
-- fix_31_creditors_fix.sql — Perbaikan dropdown nama bon kosong
-- Penyebab: tabel creditors/debts tidak punya policy RLS utk anon,
-- sedangkan get_creditors() berjalan sebagai invoker (anon) -> RLS
-- menolak -> dropdown selalu kosong walau data sudah masuk.
-- Solusi: get_creditors() jadi security definer (baca via owner).
-- Run di Supabase SQL Editor.
-- ============================================================

create or replace function get_creditors()
returns json
language sql
security definer
set search_path = public
as $$
  select coalesce(json_agg(row_to_json(t) order by t.name), '[]'::json)
  from (select id, name, phone, created_at from creditors order by name) t;
$$;

grant execute on function get_creditors() to anon;
