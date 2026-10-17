// PocketFlow external API — create a transaction (รับ / จ่าย / โอน)
//
// Auth:  Authorization: Bearer <api_key>   (key created in the app's Settings)
// Body:  { "action": "income|expense|transfer" | "รับ|จ่าย|โอน",
//          "amount": 120,
//          "account": "เงินสด" | "<account_id>",
//          "toAccount": "ธนาคาร" | "<account_id>",   // transfer only
//          "category": "อาหาร" | "<tag_id>",          // optional, income/expense
//          "note": "ข้าวเที่ยง",                       // optional
//          "date": "2026-10-17T14:30:00+07:00",       // optional, default now
//          "ref": "<slip transaction ref>",           // optional, de-duplicates
//          "dryRun": true }                           // optional, validate only
//
//        { "action": "meta" }  → lists the user's account and category names
//
// "date" accepts ISO 8601; a value without timezone is read as Bangkok time
// (+07:00) and a bare yyyy-MM-dd as noon Bangkok time. Years must be ค.ศ.
// A "ref" already used by this user returns 409 { duplicate: true, id }.
//
// Deploy: supabase functions deploy tx --no-verify-jwt
// (must NOT verify the Supabase JWT — callers authenticate with their api_key)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

async function sha256Hex(s: string): Promise<string> {
  const data = new TextEncoder().encode(s)
  const digest = await crypto.subtle.digest('SHA-256', data)
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

const MAX_REF_LENGTH = 100
const FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000

// Parse an optional transaction date. Returns null when absent, or an error message.
function parseDate(input: unknown): { date: Date | null } | { error: string } {
  if (input === undefined || input === null || input === '') return { date: null }
  if (typeof input !== 'string') return { error: 'date must be an ISO 8601 string' }
  let s = input.trim()
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) s += 'T12:00:00+07:00'
  else if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(s)) s = s.replace(' ', 'T') + '+07:00'
  const date = new Date(s)
  if (isNaN(date.getTime())) return { error: `invalid date: ${input}` }
  if (date.getTime() > Date.now() + FUTURE_TOLERANCE_MS) {
    return { error: `date is in the future: ${input} (use ค.ศ. years, e.g. 2026 not 2569)` }
  }
  return { date }
}

const ACTION_MAP: Record<string, 'income' | 'expense' | 'transfer'> = {
  income: 'income', expense: 'expense', transfer: 'transfer',
  'รับ': 'income', 'จ่าย': 'expense', 'โอน': 'transfer',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405)

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // ── authenticate via api key ──────────────────────────────────────────────
  const auth = req.headers.get('Authorization') ?? ''
  const apiKey = auth.replace(/^Bearer\s+/i, '').trim()
  if (!apiKey) return json({ error: 'missing API key' }, 401)

  const keyHash = await sha256Hex(apiKey)
  const { data: keyRow } = await admin
    .from('api_keys').select('id, user_id').eq('key_hash', keyHash).maybeSingle()
  if (!keyRow) return json({ error: 'invalid API key' }, 401)

  const userId = keyRow.user_id as string
  admin.from('api_keys').update({ last_used_at: new Date().toISOString() }).eq('id', keyRow.id).then()

  // ── parse + validate ──────────────────────────────────────────────────────
  let body: Record<string, unknown>
  try { body = await req.json() } catch { return json({ error: 'invalid JSON body' }, 400) }

  // resolve accounts/tags for this user
  const [{ data: accounts }, { data: tags }] = await Promise.all([
    admin.from('accounts').select('id, name, archived').eq('user_id', userId),
    admin.from('tags').select('id, name, type').eq('user_id', userId),
  ])

  if (String(body.action ?? '').trim() === 'meta') {
    return json({
      ok: true,
      accounts: (accounts ?? []).filter((a) => !a.archived).map((a) => a.name),
      categories: (tags ?? []).map((t) => ({ name: t.name, type: t.type })),
    })
  }

  const action = ACTION_MAP[String(body.action ?? '').trim()]
  if (!action) return json({ error: "action must be income|expense|transfer|meta (รับ|จ่าย|โอน)" }, 400)

  const amount = Number(body.amount)
  if (!amount || amount <= 0) return json({ error: 'amount must be a positive number' }, 400)

  const parsedDate = parseDate(body.date)
  if ('error' in parsedDate) return json({ error: parsedDate.error }, 400)

  const externalRef = body.ref === undefined || body.ref === null ? '' : String(body.ref).trim()
  if (externalRef.length > MAX_REF_LENGTH) return json({ error: `ref must be at most ${MAX_REF_LENGTH} characters` }, 400)

  const findAccount = (ref: unknown): { id: string } | null => {
    const s = String(ref ?? '').trim()
    if (!s) return null
    const byId = accounts?.find((a) => a.id === s)
    if (byId) return byId
    const byName = accounts?.find((a) => a.name.toLowerCase() === s.toLowerCase())
    return byName ?? null
  }

  const account = findAccount(body.account)
  if (!account) return json({ error: `account not found: ${body.account ?? '(missing)'}` }, 400)

  let toAccountId: string | null = null
  if (action === 'transfer') {
    const to = findAccount(body.toAccount)
    if (!to) return json({ error: `toAccount not found: ${body.toAccount ?? '(missing)'}` }, 400)
    if (to.id === account.id) return json({ error: 'account and toAccount must differ' }, 400)
    toAccountId = to.id
  }

  let tagId: string | null = null
  if (action !== 'transfer' && body.category) {
    const s = String(body.category).trim()
    const tag = tags?.find((t) => t.id === s) ?? tags?.find((t) => t.name.toLowerCase() === s.toLowerCase())
    if (!tag) return json({ error: `category not found: ${body.category}` }, 400)
    tagId = tag.id
  }

  // ── de-duplicate by ref ───────────────────────────────────────────────────
  const findByRef = async () => (await admin
    .from('transactions').select('id').eq('user_id', userId).eq('external_ref', externalRef).maybeSingle()).data
  if (externalRef) {
    const existing = await findByRef()
    if (existing) return json({ error: 'duplicate ref', duplicate: true, id: existing.id }, 409)
  }

  // ── insert transaction ────────────────────────────────────────────────────
  const row = {
    id: crypto.randomUUID(),
    user_id: userId,
    type: action,
    amount,
    account_id: account.id,
    to_account_id: toAccountId,
    tag_id: tagId,
    note: typeof body.note === 'string' ? body.note : '',
    date: (parsedDate.date ?? new Date()).toISOString(),
    is_recurring: false,
    // only sent when present, so calls without ref work even before the migration
    ...(externalRef ? { external_ref: externalRef } : {}),
  }
  const result = { action, amount, date: row.date, accountId: account.id, toAccountId, tagId, ref: externalRef || null }
  if (body.dryRun === true) return json({ ok: true, dryRun: true, ...result })

  const { error } = await admin.from('transactions').insert(row)
  if (error?.code === '23505' && externalRef) {
    // lost a race with a concurrent request carrying the same ref
    const existing = await findByRef()
    return json({ error: 'duplicate ref', duplicate: true, id: existing?.id ?? null }, 409)
  }
  if (error) return json({ error: error.message }, 500)

  return json({ ok: true, id: row.id, ...result })
})
