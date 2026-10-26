// Edge Function: product-image
// Upload foto produk ke Cloudinary (signed, server-side) + simpan URL ke products.image_url.
// Auth: PIN admin (dibandingkan dengan env ADMIN_PIN) — sama dengan PIN dashboard.
// Body JSON: { pin, productId, fileB64 (base64 file), fileName }
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (o: any, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } })

const SB_URL = Deno.env.get('SUPABASE_URL')!
const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ADMIN_PIN = Deno.env.get('ADMIN_PIN') || ''
const CLOUD_NAME = Deno.env.get('CLOUDINARY_CLOUD_NAME') || ''
const API_KEY = Deno.env.get('CLOUDINARY_API_KEY') || ''
const API_SECRET = Deno.env.get('CLOUDINARY_API_SECRET') || ''

async function sha1Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(s))
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, message: 'Method tidak didukung.' }, 405)
  try {
    if (!CLOUD_NAME || !API_KEY || !API_SECRET) return json({ ok: false, message: 'Cloudinary belum dikonfigurasi (secrets belum di-set).' }, 503)
    const body = await req.json().catch(() => null)
    const pin = String(body?.pin || '')
    const productId = String(body?.productId || '')
    const fileB64 = String(body?.fileB64 || '')
    const fileName = String(body?.fileName || 'product.jpg')
    if (!ADMIN_PIN || pin !== ADMIN_PIN) return json({ ok: false, message: 'PIN admin salah.' }, 401)
    if (!productId || !fileB64) return json({ ok: false, message: 'Data tidak lengkap.' }, 400)
    if (fileB64.length > 8 * 1024 * 1024) return json({ ok: false, message: 'File terlalu besar (maks ±6 MB).' }, 413)

    // validasi produk ada
    const sb = createClient(SB_URL, SRK, { auth: { persistSession: false } })
    const { data: prod, error: perr } = await sb.from('products').select('id, name').eq('id', productId).maybeSingle()
    if (perr || !prod) return json({ ok: false, message: 'Produk tidak dikenal: ' + productId }, 404)

    // signature Cloudinary: params sorted + secret
    const ts = Math.floor(Date.now() / 1000)
    const publicId = 'products/' + productId + '-' + ts
    const params: Record<string, string> = { public_id: publicId, timestamp: String(ts) }
    const toSign = Object.keys(params).sort().map(k => `${k}=${params[k]}`).join('&') + API_SECRET
    const signature = await sha1Hex(toSign)

    const form = new FormData()
    form.append('file', 'data:image/jpeg;base64,' + fileB64.replace(/^data:[^;]+;base64,/, ''))
    form.append('api_key', API_KEY)
    form.append('timestamp', String(ts))
    form.append('public_id', publicId)
    form.append('signature', signature)
    const up = await fetch(`https://api.cloudinary.com/v1_1/${CLOUD_NAME}/image/upload`, { method: 'POST', body: form })
    const ud = await up.json()
    if (!up.ok || !ud.secure_url) {
      return json({ ok: false, message: 'Upload Cloudinary gagal: ' + JSON.stringify(ud).slice(0, 200) }, 502)
    }
    // URL dengan transformasi hemat: f_auto,q_auto
    const secure = ud.secure_url as string
    const optimized = secure.replace('/upload/', '/upload/f_auto,q_auto/')

    const { error: uerr } = await sb.from('products').update({ image_url: optimized }).eq('id', productId)
    if (uerr) return json({ ok: false, message: 'Simpan URL gagal: ' + uerr.message }, 500)
    return json({ ok: true, imageUrl: optimized, publicId })
  } catch (e: any) {
    return json({ ok: false, message: 'Error: ' + (e && e.message ? e.message : String(e)) }, 500)
  }
})
