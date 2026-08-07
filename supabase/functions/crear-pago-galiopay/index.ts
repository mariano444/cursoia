import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GALIOPAY_CLIENT_ID = Deno.env.get("GALIOPAY_CLIENT_ID")!;
const GALIOPAY_API_KEY = Deno.env.get("GALIOPAY_API_KEY")!;
const SITE_URL = Deno.env.get("SITE_URL") || "http://localhost:3000";
const COURSE_PRICE_ARS = Number(Deno.env.get("COURSE_PRICE_ARS") || "4990");
const GALIOPAY_SANDBOX = (Deno.env.get("GALIOPAY_SANDBOX") || "false") === "true";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function safeReferenceId(userId: string) {
  const suffix = crypto.randomUUID().slice(0, 8);
  return `academia-${userId.slice(0, 8)}-${Date.now()}-${suffix}`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Falta sesión de Supabase" }, 401);

    const { data: userData, error: userError } = await admin.auth.getUser(
      authHeader.replace("Bearer ", ""),
    );
    if (userError || !userData.user) return json({ error: "Sesión inválida" }, 401);

    const body = await req.json();
    const nombre = String(body.nombre || "").trim();
    const email = String(body.email || userData.user.email || "").trim().toLowerCase();
    const telefono = String(body.telefono || "").trim();
    const courseSlug = String(body.course_slug || "ia-generativa-2026");

    if (!nombre || !email) return json({ error: "Nombre y email son obligatorios" }, 400);

    const { data: course, error: courseError } = await admin
      .from("courses")
      .select("id,title")
      .eq("slug", courseSlug)
      .single();
    if (courseError || !course) return json({ error: "Curso no encontrado" }, 404);

    await admin.from("profiles").upsert({
      id: userData.user.id,
      email,
      full_name: nombre,
      updated_at: new Date().toISOString(),
    });

    const referenceId = safeReferenceId(userData.user.id);
    const { error: orderError } = await admin.from("payment_orders").insert({
      reference_id: referenceId,
      user_id: userData.user.id,
      course_id: course.id,
      payer_name: nombre,
      payer_email: email,
      payer_phone: telefono,
      amount: COURSE_PRICE_ARS,
      currency: "ARS",
      status: "pending",
    });
    if (orderError) throw orderError;

    const successUrl = `${SITE_URL.replace(/\/$/, "")}/#pago-exitoso`;
    const failureUrl = `${SITE_URL.replace(/\/$/, "")}/#pago-fallido`;
    const notificationUrl = `${SUPABASE_URL}/functions/v1/galiopay-webhook`;

    const galioRes = await fetch("https://pay.galio.app/api/payment-links", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${GALIOPAY_API_KEY}`,
        "x-client-id": GALIOPAY_CLIENT_ID,
      },
      body: JSON.stringify({
        items: [{
          title: course.title || "Curso de IA Generativa 2026",
          quantity: 1,
          unitPrice: COURSE_PRICE_ARS,
          currencyId: "ARS",
        }],
        referenceId,
        notificationUrl,
        sandbox: GALIOPAY_SANDBOX,
        backUrl: { success: successUrl, failure: failureUrl },
      }),
    });

    const galioBody = await galioRes.json().catch(() => ({}));
    if (!galioRes.ok || !galioBody.url) {
      await admin.from("payment_orders")
        .update({ status: "failed", galiopay_raw: galioBody })
        .eq("reference_id", referenceId);
      return json({ error: galioBody.error || "GalioPay no pudo crear el link" }, 502);
    }

    await admin.from("payment_orders")
      .update({ galiopay_url: galioBody.url, galiopay_raw: galioBody })
      .eq("reference_id", referenceId);

    return json({ url: galioBody.url, referenceId });
  } catch (error) {
    console.error(error);
    return json({ error: error?.message || "Error interno" }, 500);
  }
});
