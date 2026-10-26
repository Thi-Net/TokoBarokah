-- Fix 17 — pasang foto Cloudinary untuk produk tertentu
-- Jalankan di Supabase SQL Editor.
update products set image_url = 'https://res.cloudinary.com/wztzcfc6/image/upload/f_auto/q_auto/garam-halus-daun.jpg'
where id = 'PRD-067'; -- Garam halus daun
