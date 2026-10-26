// ============================================================
// Edge Function: mayar-webhook
// Menerima webhook Mayar. Event yang diproses: payment sukses
// (event 'payment.received' / status SUCCESS atau PAID).
// Aksi: panggil RPC shop_confirm_mayar_payment (idempotent) yang
// menjalankan handler "Payment Sukses" yang sudah ada:
// status -> paid, kurangi stok via stock_ledger, catat penjualan POS.
// Verifikasi: header x-mayar-token / Authorization Bearer /
// query ?token= harus sama dengan MAYAR_WEBHOOK_TOKEN.
// URL untuk dashboard Mayar:
//   https://zosdcuiulgpjevgbyquw.supabase.co/functions/v1/mayar-webhook
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = Deno.env.get('SUPABASE_URL')!
const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const WEBHOOK_TOKEN = Deno.env.get('MAYAR_WEBHOOK_TOKEN') ?? ''

Deno.serve(async (req: Request) => {
  try {
    // --- verifikasi token webhook ---
    const url = new URL(req.url)
    const hdrToken =
      req.headers.get('x-mayar-token') ??
      (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '') ??
      ''
    const qToken = url.searchParams.get('token') ?? ''
    if (WEBHOOK_TOKEN && hdrToken !== WEBHOOK_TOKEN && qToken !== WEBHOOK_TOKEN) {
      return new Response(JSON.stringify({ ok: false, message: 'Token webhook salah.' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    const payload = await req.json().catch(() => null)
    const data = (payload?.data ?? payload) as Record<string, unknown>
    const event = String(payload?.event ?? '')
    const status = String(data?.status ?? '').toUpperCase()
    const txnId = String(data?.transactionId ?? data?.id ?? '')

    // Hanya proses pembayaran sukses; selain itu balas 200 agar Mayar tidak retry terus
    const isPaid =
      event === 'payment.received' ||
      status === 'SUCCESS' || status === 'PAID'
    if (!isPaid || !txnId) {
      return new Response(JSON.stringify({ ok: true, ignored: true, event, status }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }

    const sb = createClient(SB_URL, SRK, { auth: { persistSession: false } })
    const { data: res, error } = await sb.rpc('shop_confirm_mayar_payment', {
      p_transaction_id: txnId,
    })
    if (error) {
      console.error('confirm rpc error', error)
      // balas 500 supaya Mayar mencoba ulang (stok belum berkurang)
      return new Response(JSON.stringify({ ok: false, message: error.message }), {
        status: 500, headers: { 'Content-Type': 'application/json' },
      })
    }
    return new Response(JSON.stringify({ ok: true, result: res }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (e) {
    console.error('mayar-webhook exception', e)
    return new Response(JSON.stringify({ ok: false }), { status: 500 })
  }
})
