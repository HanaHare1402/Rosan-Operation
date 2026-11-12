import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

// Chỉ trang của công ty được gọi function từ trình duyệt (lịch cron gọi từ máy chủ, không cần CORS).
// Thêm tên miền mới vào ALLOWED_ORIGINS (biến môi trường của Edge Function, cách nhau dấu phẩy) nếu cần.
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") || "https://rosangroup.vn,https://www.rosangroup.vn,https://hanahare1402.github.io")
  .split(",").map((x) => x.trim()).filter(Boolean);
export const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": ALLOWED[0],
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
// Gắn đúng tên miền người gọi vào câu trả lời nếu nằm trong danh sách cho phép (mỗi request riêng, không dùng chung biến).
export function withCors(req: Request, res: Response): Response {
  const o = req.headers.get("Origin") || "";
  const ok = ALLOWED.includes(o) || /^http:\/\/localhost(:\d+)?$/.test(o);
  const h = new Headers(res.headers);
  h.set("Access-Control-Allow-Origin", ok ? o : ALLOWED[0]);
  h.set("Vary", "Origin");
  return new Response(res.body, { status: res.status, headers: h });
}

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
