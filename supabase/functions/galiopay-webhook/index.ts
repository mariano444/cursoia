import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("GALIOPAY_WEBHOOK_SECRET") || "";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function hex(buffer: ArrayBuffer) {
  return [...new Uint8Array(buffer)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function verifySignature(req: Request, rawBody: string) {
  if (!WEBHOOK_SECRET) return true;
  const timestamp = req.headers.get("X-GalioPay-Timestamp");
  const signatureHeader = req.headers.get("X-GalioPay-Signature") || "";
  const received = signatureHeader.replace(/^v1=/, "");
  if (!timestamp || !received) return false;

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(timestamp)) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${rawBody}`),
  );
  return hex(signature) === received;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const rawBody = await req.text();
  const valid = await verifySignature(req, rawBody);
  if (!valid) return json({ error: "Invalid signature" }, 401);

  let event: Record<string, unknown>;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const referenceId = String(event.referenceId || "");
  const status = String(event.status || "");
  const paymentId = event.id ? String(event.id) : null;
  if (!referenceId || !status) return json({ error: "Missing referenceId/status" }, 400);

  const { error } = await admin.rpc("activate_enrollment_from_payment", {
    p_reference_id: referenceId,
    p_payment_id: paymentId,
    p_status: status,
    p_payload: event,
  });
  if (error) {
    console.error(error);
    return json({ error: error.message }, 500);
  }

  return json({ ok: true });
});
