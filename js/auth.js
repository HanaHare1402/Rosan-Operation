// Dùng chung cho mọi trang: tạo Supabase client, kiểm tra đăng nhập, đọc vai trò.
(function () {
  const cfg = window.APP_CONFIG || {};
  const ROLES = {
    admin: "Admin",
    quan_ly: "Quản lý",
    marketing: "Marketing",
    ke_toan: "Kế toán",
    van_don: "Vận đơn",
    kho: "Kho",
    sale: "Sale",
  };
  // Màn nào của bảng điều hành mỗi vai trò được xem.
  const VIEWS = {
    admin: ["tongquan", "team", "nhansu", "sanpham", "donhang", "kqkd", "canhbao", "caidat"],
    quan_ly: ["tongquan", "team", "nhansu", "sanpham", "donhang", "kqkd", "canhbao", "caidat"],
    marketing: ["tongquan", "team", "nhansu", "sanpham", "canhbao"],
    ke_toan: ["tongquan", "donhang", "kqkd", "canhbao", "caidat"],
    van_don: ["donhang", "canhbao"],
    kho: ["sanpham", "donhang", "canhbao"],
    sale: ["donhang", "sanpham"],
  };

  const TEAMS = { phong: "Team Phong", mung: "Team Mừng", hieu: "Team Hiếu", nhung: "Team Nhung", san: "Team Sàn" };
  const CHANNELS = { fb: "Facebook", gg: "Google", tiktok: "TikTok", shopee: "Shopee", lazada: "Lazada", khac: "Khác" };

  const configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY);
  const sb = configured && window.supabase ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  async function loadProfile() {
    if (!sb) return null;
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return null;
    const { data, error } = await sb.from("profiles").select("id, email, full_name, role, team").eq("id", session.user.id).maybeSingle();
    if (error) throw error;
    return data || { id: session.user.id, email: session.user.email, full_name: "", role: null, team: null };
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

  async function signOut() { if (sb) await sb.auth.signOut(); location.replace("login.html"); }

  window.Auth = { sb, configured, ROLES, VIEWS, TEAMS, CHANNELS, loadProfile, requireAuth, callFn, signOut };
})();
