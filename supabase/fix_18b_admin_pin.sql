-- Fix 18b — ubah PIN admin (tabel app_settings)
update app_settings set value = '123790' where key = 'admin_pin';
