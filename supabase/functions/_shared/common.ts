import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// Client service role: bỏ qua RLS, chỉ dùng trong function.
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export type Caller = { id: string; email: string; role: string | null };

// Đọc người gọi từ header Authorization; trả null nếu không đăng nhập.
export async function getCaller(req: Request, sb: SupabaseClient): Promise<Caller | null> {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data.user) return null;
  const { data: p } = await sb.from("profiles").select("role").eq("id", data.user.id).maybeSingle();
  return { id: data.user.id, email: data.user.email || "", role: p?.role ?? null };
}
