-- ============================================================
-- fix_33_cicilan.sql — Piutang bisa dicicil (tidak langsung lunas)
-- 1) tabel debt_payments (riwayat cicilan)
-- 2) add_debt_payment: catat cicilan (PIN-guard); lunas OTOMATIS
--    hanya saat total cicilan >= jumlah utang
-- 3) get_piutang: kirim paid (sudah dicicil) & remaining (sisa) per piutang
-- 4) pay_debt: pelunasan penuh sekaligus (tetap ada) — dihitung dari sisa
-- Run di Supabase SQL Editor.
-- ============================================================

-- ---------- 1) riwayat cicilan ----------
create table if not exists debt_payments (
  id text primary key,
  debt_id text not null references debts(id),
  amount numeric not null,
  note text,
  created_at timestamptz default now()
);
create index if not exists idx_debt_payments_debt on debt_payments(debt_id, created_at);

-- ---------- 2) catat cicilan ----------
create or replace function add_debt_payment(p_pin text, p_debt_id text, p_amount numeric, p_note text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_debt record;
  v_paid numeric;
  v_id text;
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  if p_amount is null or p_amount <= 0 then
    return json_build_object('ok', false, 'message', 'Nominal cicilan harus lebih dari 0');
  end if;
  select * into v_debt from debts where id = p_debt_id;
  if not found then
    return json_build_object('ok', false, 'message', 'Piutang tidak ditemukan');
  end if;
  if v_debt.status = 'paid' then
    return json_build_object('ok', false, 'message', 'Piutang sudah lunas');
  end if;
  select coalesce(sum(amount),0) into v_paid from debt_payments where debt_id = p_debt_id;
  if p_amount > (v_debt.amount - v_paid) then
    return json_build_object('ok', false, 'message', 'Cicilan melebihi sisa utang (sisa Rp' || to_char(v_debt.amount - v_paid, 'FM999999999') || ')');
  end if;
  v_id := 'DPY-' || to_char(now(),'YYMMDDHH24MISS') || floor(random()*90+10)::int;
  insert into debt_payments (id, debt_id, amount, note) values (v_id, p_debt_id, p_amount, nullif(btrim(coalesce(p_note,'')), ''));
  -- lunas otomatis kalau cicilan mencapai jumlah utang
  if v_paid + p_amount >= v_debt.amount then
    update debts set status = 'paid', paid_at = now() where id = p_debt_id;
    return json_build_object('ok', true, 'message', 'Cicilan Rp' || to_char(p_amount,'FM999999999') || ' tercatat — piutang LUNAS', 'paymentId', v_id, 'lunas', true);
  end if;
  return json_build_object('ok', true, 'message', 'Cicilan Rp' || to_char(p_amount,'FM999999999') || ' tercatat (sisa Rp' || to_char(v_debt.amount - v_paid - p_amount, 'FM999999999') || ')', 'paymentId', v_id, 'lunas', false);
end;
$$;

-- ---------- 3) get_piutang: + paid/remaining + riwayat cicilan ----------
create or replace function get_piutang(p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_rows json;
  v_open numeric;
  v_paid_month numeric;
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  select coalesce(json_agg(json_build_object(
    'id', d.id,
    'creditorId', d.creditor_id,
    'creditorName', c.name,
    'amount', d.amount,
    'paid', coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0),
    'remaining', d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0),
    'payments', coalesce((select json_agg(json_build_object('id', p.id, 'amount', p.amount, 'note', p.note, 'createdAt', p.created_at) order by p.created_at) from debt_payments p where p.debt_id = d.id), '[]'::json),
    'saleIds', d.sale_ids,
    'status', d.status,
    'createdAt', d.created_at,
    'paidAt', d.paid_at
  ) order by case when d.status = 'open' then 0 else 1 end, d.created_at desc), '[]'::json)
  into v_rows
  from debts d join creditors c on c.id = d.creditor_id;

  select coalesce(sum(amount),0) - coalesce((select sum(p.amount) from debt_payments p join debts d on d.id = p.debt_id where d.status = 'open'), 0)
    into v_open
  from debts where status = 'open';
  select coalesce(sum(p.amount),0) into v_paid_month
    from debt_payments p
    where (p.created_at at time zone 'Asia/Jakarta')::date >= (now() at time zone 'Asia/Jakarta')::date - interval '30 days';

  return json_build_object('ok', true, 'debts', v_rows, 'totalOpen', v_open, 'paidLast30d', v_paid_month);
end;
$$;

-- ---------- 4) pay_debt: pelunasan penuh = sisanya ----------
create or replace function pay_debt(p_pin text, p_debt_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_debt record;
  v_paid numeric;
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  select * into v_debt from debts where id = p_debt_id and status = 'open';
  if not found then
    return json_build_object('ok', false, 'message', 'Piutang tidak ditemukan / sudah lunas');
  end if;
  select coalesce(sum(amount),0) into v_paid from debt_payments where debt_id = p_debt_id;
  -- sisanya dicatat sebagai pembayaran pelunasan agar riwayat utuh
  if v_debt.amount - v_paid > 0 then
    insert into debt_payments (id, debt_id, amount, note)
    values ('DPY-' || to_char(now(),'YYMMDDHH24MISS') || floor(random()*90+10)::int, p_debt_id, v_debt.amount - v_paid, 'Pelunasan');
  end if;
  update debts set status = 'paid', paid_at = now() where id = p_debt_id;
  return json_build_object('ok', true, 'message', 'Piutang ' || p_debt_id || ' dilunasi (Rp' || to_char(v_debt.amount - v_paid, 'FM999999999') || ')');
end;
$$;

grant execute on function add_debt_payment(text,text,numeric,text) to anon;
grant execute on function get_piutang(text) to anon;
grant execute on function pay_debt(text,text) to anon;
