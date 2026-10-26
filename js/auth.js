// Dùng chung cho mọi trang: tạo Supabase client, kiểm tra đăng nhập, đọc vai trò.
(function () {
  const cfg = window.APP_CONFIG || {};
  const ROLES = {
    admin: "Admin",
    quan_ly: "Quản lý",
    truong_team: "Trưởng team",
    marketing: "Marketing",
    ke_toan: "Kế toán",
    van_don: "Vận đơn",
    kho: "Kho",
    sale: "Sale",
  };
  // Màn nào của bảng điều hành mỗi vai trò được xem.
  const VIEWS = {
    admin: ["tongquan", "team", "nhansu", "sanpham", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    quan_ly: ["tongquan", "team", "nhansu", "sanpham", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    truong_team: ["tongquan", "team", "nhansu", "sanpham", "donhang", "kpi", "chiphi", "canhbao"],
    marketing: ["tongquan", "nhansu", "sanpham", "donhang", "kpi", "chiphi", "canhbao"],
    ke_toan: ["tongquan", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    van_don: ["donhang", "canhbao"],
    kho: ["sanpham", "donhang", "canhbao"],
    sale: ["tongquan", "nhansu", "donhang", "sanpham"],
  };

  // Phạm vi xem: quyết định tài khoản thấy đơn nào.
  const SCOPES = {
    all: "Toàn công ty",
    project: "Dự án được gán",
    team: "Team được gán",
    self: "Chỉ của mình",
  };
  const DEFAULT_SCOPE = { admin: "all", ke_toan: "all", quan_ly: "project", van_don: "project", kho: "project", truong_team: "team", marketing: "self", sale: "self" };

  // Tab nào của trang Quản trị mỗi vai trò được vào.
  const ADMIN_TABS = {
    danhmuc: ["admin", "quan_ly"],
    chuakhaibao: ["admin", "quan_ly"],
    giavon: ["admin", "quan_ly", "ke_toan"],
    nhomsp: ["admin", "quan_ly", "ke_toan"],
    pos: ["admin"],
    taikhoan: ["admin"],
    nhatky: ["admin"],
  };

  const configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY);
  const sb = configured && window.supabase ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  async function loadProfile() {
    if (!sb) return null;
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return null;
    const { data, error } = await sb.from("profiles").select("id, email, full_name, role, scope, project_ids, team_id, staff_id").eq("id", session.user.id).maybeSingle();
    if (error) throw error;
    return data || { id: session.user.id, email: session.user.email, full_name: "", role: null, scope: "self", project_ids: [], team_id: null, staff_id: null };
  }

  // Trang cần đăng nhập: chưa đăng nhập thì chuyển về login.html.
  async function requireAuth() {
    if (!configured) { location.replace("login.html"); return new Promise(() => {}); }
    const profile = await loadProfile().catch(() => null);
    if (!profile) { location.replace("login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.hash)); return new Promise(() => {}); }
    sb.auth.onAuthStateChange((ev) => { if (ev === "SIGNED_OUT") location.replace("login.html"); });
    return profile;
  }

  // Gọi Edge Function; trả lỗi tiếng Việt đọc được thay vì "non-2xx".
  async function callFn(name, body) {
    const { data, error } = await sb.functions.invoke(name, { body });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); if (j && j.error) msg = j.error; } catch (e) {}
      throw new Error(msg);
    }
    if (data && data.error) throw new Error(data.error);
    return data;
  }

  // Danh mục dùng chung: dự án, team, thị trường, kênh, nhân sự.
  async function loadCatalog() {
    const q = (t, order) => sb.from(t).select("*").order(order || "name");
    const [p, t, m, c, s] = await Promise.all([q("projects", "sort"), q("teams"), q("markets"), q("channels", "sort"), q("staff")]);
    for (const r of [p, t, m, c, s]) if (r.error) throw r.error;
    return { projects: p.data, teams: t.data, markets: m.data, channels: c.data, staff: s.data };
  }

  async function signOut() { if (sb) await sb.auth.signOut(); location.replace("login.html"); }

  window.Auth = { sb, configured, ROLES, VIEWS, ADMIN_TABS, SCOPES, DEFAULT_SCOPE, loadCatalog, loadProfile, requireAuth, callFn, signOut };
})();
