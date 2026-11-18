import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://digital-supply-chain-360.husanovkamron520.workers.dev",
]);
const headersFor = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin && allowedOrigins.has(origin) ? origin : "null",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
  "Content-Type": "application/json",
});

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const headers = headersFor(origin);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST" || !origin || !allowedOrigins.has(origin)) {
    return new Response(JSON.stringify({ error: "Origin or method not allowed" }), { status: 403, headers });
  }

  try {
    const body = await req.json();
    const token = String(body?.token ?? "");
    const password = String(body?.password ?? "");
    if (!/^[a-fA-F0-9]{64}$/.test(token)) {
      return new Response(JSON.stringify({ error: "Recovery link is invalid or expired. Request a new link in Telegram." }), { status: 400, headers });
    }
    if (password.length < 8 || password.length > 128) {
      return new Response(JSON.stringify({ error: "Password must be 8–128 characters." }), { status: 400, headers });
    }

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) throw new Error("Recovery service configuration is missing.");
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

    // Claim the one-time token server-side before performing the privileged update.
    const { data: claim, error: claimError } = await admin.rpc("consume_telegram_password_recovery", { p_token: token });
    if (claimError || !claim?.user_id || !claim?.telegram_user_id) {
      return new Response(JSON.stringify({ error: claimError?.message || "Recovery token is invalid or expired." }), { status: 400, headers });
    }

    const { error: updateError } = await admin.auth.admin.updateUserById(claim.user_id, { password });
    if (updateError) {
      // Token has been consumed; ask user to request a fresh recovery link in Telegram.
      return new Response(JSON.stringify({ error: "Password could not be updated. Request a new recovery link in Telegram." }), { status: 400, headers });
    }
    return new Response(JSON.stringify({ success: true, telegram_user_id: String(claim.telegram_user_id) }), { status: 200, headers });
  } catch (_error) {
    // Avoid returning/logging secrets or account details.
    return new Response(JSON.stringify({ error: "Password recovery service is temporarily unavailable." }), { status: 500, headers });
  }
});
