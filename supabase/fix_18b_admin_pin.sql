-- Fix 18b (v2) — buat tabel app_settings bila belum ada + set PIN admin
create table if not exists app_settings (
  key text primary key,
  value text not null
);

insert into app_settings (key, value) values ('admin_pin', '123790')
on conflict (key) do update set value = excluded.value;
