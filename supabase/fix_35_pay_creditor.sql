-- ============================================================
-- fix_35_pay_creditor.sql — Pelunasan & cicilan piutang per NAMA
-- (bukan per transaksi). Nominal dialokasikan otomatis ke
-- transaksi-transaksi bon orang itu, dari yang TERTUA dulu.
-- pay_creditor(p_pin, p_creditor_id, p_amount null/0 = lunas semua,
--              p_note opsional)
-- Run di Supabase SQL Editor.
-- ============================================================

create or replace function pay_creditor(
  p_pin text,
  p_creditor_id text,
  p_amount numeric default null,
  p_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored text;
  v_open record;
  v_total_remaining numeric := 0;
  v_sisa numeric;
  v_take numeric;
  v_paid_now numeric := 0;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select value into v_stored from app_settings where key = 'admin_pin';
  if v_stored is null or p_pin is null or p_pin <> v_stored then
    return json_build_object('ok', false, 'message', 'PIN Admin salah');
  end if;
  if not exists (select 1 from creditors where id = p_creditor_id) then
    return json_build_object('ok', false, 'message', 'Nama peminjam tidak ditemukan');
  end if;

  select coalesce(sum(d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0)), 0)
    into v_total_remaining
  from debts d where d.creditor_id = p_creditor_id and d.status = 'open';

  if v_total_remaining <= 0 then
    return json_build_object('ok', false, 'message', 'Tidak ada piutang aktif untuk nama ini');
  end if;

  -- lunas semua
  if p_amount is null or p_amount <= 0 or p_amount >= v_total_remaining then
    for v_open in
      select d.id, d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0) as rem
      from debts d where d.creditor_id = p_creditor_id and d.status = 'open'
      order by d.created_at
    loop
      if v_open.rem > 0 then
        insert into debt_payments (id, debt_id, amount, note)
        values ('DPY-' || to_char(now(),'YYMMDDHH24MISS') || floor(random()*90+10)::int, v_open.id, v_open.rem, coalesce(v_note, 'Pelunasan'));
      end if;
      update debts set status = 'paid', paid_at = now() where id = v_open.id;
      v_paid_now := v_paid_now + v_open.rem;
    end loop;
    return json_build_object('ok', true, 'message',
      'Piutang LUNAS — Rp' || to_char(v_paid_now, 'FM999999999') || ' tercatat');
  end if;

  -- cicilan: alokasikan tertua dulu
  if p_amount > v_total_remaining then
    return json_build_object('ok', false, 'message', 'Melebihi total sisa utang (sisa Rp' || to_char(v_total_remaining, 'FM999999999') || ')');
  end if;
  v_sisa := p_amount;
  for v_open in
    select d.id, d.amount - coalesce((select sum(p.amount) from debt_payments p where p.debt_id = d.id), 0) as rem
    from debts d where d.creditor_id = p_creditor_id and d.status = 'open'
    order by d.created_at
  loop
    exit when v_sisa <= 0;
    v_take := least(v_open.rem, v_sisa);
    if v_take > 0 then
      insert into debt_payments (id, debt_id, amount, note)
      values ('DPY-' || to_char(now(),'YYMMDDHH24MISS') || floor(random()*90+10)::int, v_open.id, v_take, v_note);
      v_sisa := v_sisa - v_take;
      v_paid_now := v_paid_now + v_take;
      -- transaksi itu lunas otomatis kalau cicilannya mencapai jumlahnya
      if v_take = v_open.rem then
        update debts set status = 'paid', paid_at = now() where id = v_open.id;
      end if;
    end if;
  end loop;

  return json_build_object('ok', true, 'message',
    'Cicilan Rp' || to_char(v_paid_now, 'FM999999999') || ' tercatat (sisa total Rp' || to_char(v_total_remaining - v_paid_now, 'FM999999999') || ')');
end;
$$;
grant execute on function pay_creditor(text,text,numeric,text) to anon;
