// ============================================================
// Edge Function: mayar-create
// Membuat tagihan Mayar saat customer pilih Transfer/QRIS.
// Input : { token, orderId, method: 'transfer'|'qris' }
// Output: { ok, link, paymentId, amount, method }
// Secret yang wajib di-set (supabase secrets set):
//   MAYAR_API_KEY, MAYAR_WEBHOOK_TOKEN, (opsional) MAYAR_BASE_URL
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = Deno.env.get('SUPABASE_URL')!
const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const MAYAR_API_KEY = Deno.env.get('MAYAR_API_KEY') ?? ''
const MAYAR_BASE_URL = Deno.env.get('MAYAR_BASE_URL') ?? 'https://api.mayar.io/hl/v1'
const SHOP_URL = 'https://tokobarokah.vercel.app/shop'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, message: 'Method tidak didukung.' }, 405)

  try {
    if (!MAYAR_API_KEY) {
      return json({ ok: false, message: 'Pembayaran online belum aktif (MAYAR_API_KEY belum di-set).' }, 503)
    }

    const body = await req.json().catch(() => null)
    const token = body?.token ?? ''
    const orderId = body?.orderId ?? ''
    const method = body?.method ?? ''
    if (!token || !orderId) return json({ ok: false, message: 'Data tidak lengkap.' }, 400)
    if (method !== 'transfer' && method !== 'qris') {
      return json({ ok: false, message: 'Metode bayar tidak valid.' }, 400)
    }

    const sb = createClient(SB_URL, SRK, { auth: { persistSession: false } })

    // Validasi sesi customer (helper yang sama dengan alur demo)
    const { data: cid, error: authErr } = await sb.rpc('_shop_auth', { p_token: token })
    if (authErr) return json({ ok: false, message: 'Gagal validasi sesi.' }, 500)
    if (!cid) return json({ ok: false, message: 'Sesi tidak valid. Login ulang.' }, 401)

    // Muat pesanan milik customer ini
    const { data: order, error: ordErr } = await sb
      .from('orders').select('*')
      .eq('id', orderId).eq('customer_id', cid).single()
    if (ordErr || !order) return json({ ok: false, message: 'Order tidak ditemukan.' }, 404)
    if (order.status !== 'pending') {
      return json({ ok: false, message: 'Order sudah diproses/dibayar.' }, 409)
    }

    // Nama & HP customer untuk tagihan Mayar
    const { data: cust } = await sb
      .from('customers').select('name, phone, email')
      .eq('id', cid).single()
    const custName = cust?.name || 'Pelanggan Toko Barokah'
    // Mobile harus <=15 karakter & numerik utk Mayar; customer email-based tidak punya HP valid
    const digits = (cust?.phone || '').replace(/\D/g, '')
    const custPhone = digits.length >= 9 && digits.length <= 15 ? digits : ''
    const custEmail = cust?.email || 'cs@tokobarokah.example'

    // Guard idempoten: jangan buat tagihan dua kali untuk order yang sama
    const { data: existing } = await sb
      .from('payments').select('id, mayar_transaction_id, mayar_link, amount')
      .eq('order_id', orderId).eq('provider', 'mayar').maybeSingle()
    if (existing && existing.mayar_link) {
      return json({ ok: true, link: existing.mayar_link, paymentId: existing.id, amount: existing.amount, method })
    }

    // Panggil Mayar Headless API. Batas waktu tagihan: 1 jam untuk semua metode
    // (opsi yang dipilih owner). Countdown di halaman Mayar mengikuti nilai ini,
    // sehingga batas pembayaran pesanan = countdown Mayar yang dilihat customer.
    const expiredAt = new Date(Date.now() + 60 * 60 * 1000).toISOString()
    const mayarRes = await fetch(MAYAR_BASE_URL + '/payment/create', {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + MAYAR_API_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        name: custName,
        email: custEmail,
        mobile: custPhone,
        amount: order.total,
        description: 'Pesanan ' + orderId + ' — Toko Barokah (' + (method === 'qris' ? 'QRIS' : 'Transfer') + ')',
        redirectUrl: SHOP_URL,
        expiredAt: expiredAt,
      }),
    })
    const mayarText = await mayarRes.text()
    let mayarData: Record<string, unknown> = {}
    try { mayarData = JSON.parse(mayarText) } catch { /* biarkan kosong */ }
    if (!mayarRes.ok) {
      console.error('Mayar error', mayarRes.status, mayarText)
      return json({ ok: false, message: 'Gagal membuat tagihan pembayaran (Mayar) — status ' + mayarRes.status + ': ' + mayarText.slice(0, 200) }, 502)
    }
    const d = (mayarData.data ?? mayarData) as Record<string, unknown>
    const txnId = String(d.transactionId ?? d.transaction_id ?? d.id ?? '')
    const link = String(d.link ?? d.paymentUrl ?? d.url ?? '')
    if (!txnId || !link) {
      console.error('Mayar respons tak terduga', mayarText)
      return json({ ok: false, message: 'Respons Mayar tidak dikenali.' }, 502)
    }

    // Catat payment provider=mayar + simpan transaction id
    const pid = 'PAY-' + new Date().toISOString().replace(/\D/g, '').slice(2, 14) + '-' + Math.floor(100 + Math.random() * 900)
    const { data: pay, error: payErr } = await sb.from('payments').insert({
      id: pid,
      order_id: orderId,
      provider: 'mayar',
      method,
      amount: order.total,
      status: 'initiated',
      mayar_transaction_id: txnId,
      mayar_link: link,
    }).select('id').single()
    if (payErr) {
      console.error('Insert payment gagal', payErr)
      return json({ ok: false, message: 'Gagal mencatat pembayaran.' }, 500)
    }
    await sb.from('orders').update({ payment_method: method, updated_at: new Date().toISOString() }).eq('id', orderId)

    return json({ ok: true, paymentId: pay.id, amount: order.total, method, link, txn: txnId })
  } catch (e) {
    console.error('mayar-create exception', e)
    return json({ ok: false, message: 'Kesalahan server pembayaran.' }, 500)
  }
})
