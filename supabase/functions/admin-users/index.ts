// Quản lý tài khoản: chỉ admin gọi được. Tạo tài khoản, đổi quyền, đặt lại mật khẩu, khoá, xoá.
import { adminClient, cors, getCaller, json } from "../_shared/common.ts";

const ROLES = ["admin", "lanh_dao", "quan_ly", "truong_team", "marketing", "ke_toan", "van_don", "kho", "sale"];
const SCOPES = ["all", "project", "team", "self"];
// Phạm vi xem mặc định theo vai trò; admin chỉnh lại được từng người.
const DEFAULT_SCOPE: Record<string, string> = {
  admin: "all", lanh_dao: "all", ke_toan: "all", quan_ly: "project", van_don: "project", kho: "project", truong_team: "team", marketing: "self", sale: "self",
};

// Các trường phạm vi gửi lên (chỉ lấy trường có mặt).
function scopePatch(body: Record<string, any>, role: string | null) {
  const p: Record<string, unknown> = {};
  if ("scope" in body || "role" in body) {
    const sc = body.scope && SCOPES.includes(body.scope) ? body.scope : (role ? DEFAULT_SCOPE[role] : "self");
    p.scope = sc;
  }
  if ("project_ids" in body) p.project_ids = Array.isArray(body.project_ids) ? body.project_ids.map(String).filter(Boolean) : [];
  if ("team_id" in body) p.team_id = body.team_id || null;
  if ("staff_id" in body) p.staff_id = body.staff_id || null;
  return p;
}
const BAN_FOREVER = "876000h";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Chỉ nhận POST" }, 405);

  const sb = adminClient();
  const caller = await getCaller(req, sb);
  if (!caller) return json({ error: "Chưa đăng nhập" }, 401);
  if (caller.role !== "admin") return json({ error: "Chỉ admin được quản lý tài khoản" }, 403);

  let body: Record<string, any>;
  try { body = await req.json(); } catch { return json({ error: "Body không phải JSON" }, 400); }
  const role = body.role === "" || body.role == null ? null : String(body.role);
  if (role !== null && !ROLES.includes(role)) return json({ error: "Vai trò không hợp lệ" }, 400);

  try {
    switch (body.action) {
      case "list": {
        const users: any[] = [];
        for (let page = 1; page < 50; page++) {
          const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
          if (error) throw error;
          users.push(...data.users);
          if (data.users.length < 1000) break;
        }
        const { data: profiles, error } = await sb.from("profiles").select("id, full_name, role, scope, project_ids, team_id, staff_id");
        if (error) throw error;
        const pm = new Map(profiles.map((p) => [p.id, p]));
        return json({
          users: users.map((u) => ({
            id: u.id,
            email: u.email,
            full_name: pm.get(u.id)?.full_name ?? "",
            role: pm.get(u.id)?.role ?? null,
            scope: pm.get(u.id)?.scope ?? "self",
            project_ids: pm.get(u.id)?.project_ids ?? [],
            team_id: pm.get(u.id)?.team_id ?? null,
            staff_id: pm.get(u.id)?.staff_id ?? null,
            banned: !!u.banned_until && new Date(u.banned_until) > new Date(),
            last_sign_in_at: u.last_sign_in_at,
            created_at: u.created_at,
          })).sort((a, b) => String(a.email).localeCompare(String(b.email))),
        });
      }
      case "create": {
        const email = String(body.email || "").trim().toLowerCase();
        const password = String(body.password || "");
        if (!email || password.length < 8) return json({ error: "Cần email và mật khẩu từ 8 ký tự" }, 400);
        const { data, error } = await sb.auth.admin.createUser({
          email, password, email_confirm: true, user_metadata: { full_name: body.full_name || "" },
        });
        if (error) throw error;
        // Trigger đã tạo profile; ghi thêm tên, quyền, team.
        const { error: e2 } = await sb.from("profiles").upsert({
          id: data.user.id, email, full_name: body.full_name || "", role, ...scopePatch({ ...body, role }, role), updated_at: new Date().toISOString(),
        });
        if (e2) throw e2;
        return json({ ok: true, id: data.user.id });
      }
      case "update": {
        const id = String(body.id || "");
        if (!id) return json({ error: "Thiếu id" }, 400);
        if (id === caller.id && "role" in body && role !== "admin") return json({ error: "Không tự bỏ quyền admin của chính mình được" }, 400);
        const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
        if ("full_name" in body) patch.full_name = String(body.full_name || "");
        if ("role" in body) patch.role = role;
        Object.assign(patch, scopePatch(body, role));
        const { error } = await sb.from("profiles").update(patch).eq("id", id);
        if (error) throw error;
        return json({ ok: true });
      }
      case "set_password": {
        const password = String(body.password || "");
        if (password.length < 8) return json({ error: "Mật khẩu từ 8 ký tự" }, 400);
        const { error } = await sb.auth.admin.updateUserById(String(body.id), { password });
        if (error) throw error;
        return json({ ok: true });
      }
      case "ban":
      case "unban": {
        if (body.id === caller.id) return json({ error: "Không tự khoá chính mình được" }, 400);
        const { error } = await sb.auth.admin.updateUserById(String(body.id), {
          ban_duration: body.action === "ban" ? BAN_FOREVER : "none",
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "delete": {
        if (body.id === caller.id) return json({ error: "Không tự xoá chính mình được" }, 400);
        const { error } = await sb.auth.admin.deleteUser(String(body.id));
        if (error) throw error;
        return json({ ok: true });
      }
      default:
        return json({ error: "action không hợp lệ" }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 500);
  }
});
