// Dùng chung cho mọi trang: tạo Supabase client, kiểm tra đăng nhập, đọc vai trò.
(function () {
  const cfg = window.APP_CONFIG || {};
  const ROLES = {
    admin: "Admin",
    lanh_dao: "Ban lãnh đạo",
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
    admin: ["tongquan", "team", "nhansu", "sanpham", "tonkho", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    // Ban lãnh đạo: xem mọi báo cáo và số chi phí, không có màn nhập liệu (chi phí ads, cài đặt). Database cũng không cho ghi.
    lanh_dao: ["tongquan", "team", "nhansu", "sanpham", "tonkho", "donhang", "kqkd", "kpi", "canhbao"],
    quan_ly: ["tongquan", "team", "nhansu", "sanpham", "tonkho", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    truong_team: ["tongquan", "team", "nhansu", "sanpham", "tonkho", "donhang", "kpi", "chiphi", "canhbao"],
    marketing: ["tongquan", "nhansu", "sanpham", "tonkho", "donhang", "kpi", "chiphi", "canhbao"],
    ke_toan: ["tongquan", "tonkho", "donhang", "kqkd", "kpi", "chiphi", "canhbao", "caidat"],
    van_don: ["donhang", "canhbao"],
    kho: ["sanpham", "tonkho", "donhang", "canhbao"],
    sale: ["tongquan", "nhansu", "donhang", "sanpham"],
  };

  // Phạm vi xem: quyết định tài khoản thấy đơn nào.
  const SCOPES = {
    all: "Toàn công ty",
    project: "Dự án được gán",
    team: "Team được gán",
    self: "Chỉ của mình",
  };
  const DEFAULT_SCOPE = { admin: "all", lanh_dao: "all", ke_toan: "all", quan_ly: "project", van_don: "project", kho: "project", truong_team: "team", marketing: "self", sale: "self" };

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
  // Giữ đăng nhập trên máy (localStorage) và tự gia hạn phiên; đóng trình duyệt mở lại không phải đăng nhập lại.
  const sb = configured && window.supabase ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  }) : null;

  async function loadProfile() {
    if (!sb) return null;
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return null;
    const { data, error } = await sb.from("profiles").select("id, email, full_name, role, scope, project_ids, team_id, staff_id").eq("id", session.user.id).maybeSingle();
    if (error) throw error;
    // must_change_pw: mật khẩu do quản trị viên cấp, chưa đổi sang mật khẩu riêng.
    const must = !!(session.user.user_metadata && session.user.user_metadata.must_change_pw);
    return Object.assign(data || { id: session.user.id, email: session.user.email, full_name: "", role: null, scope: "self", project_ids: [], team_id: null, staff_id: null }, { must_change_pw: must, login_email: session.user.email });
  }

  // Trang cần đăng nhập: chỉ chuyển về login.html khi thật sự chưa đăng nhập.
  // Lỗi mạng lúc mở trang thì báo và cho tải lại, không bắt đăng nhập lại.
  async function requireAuth() {
    if (!configured) { location.replace("login.html"); return new Promise(() => {}); }
    const toLogin = () => { location.replace("login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() + location.hash)); return new Promise(() => {}); };
    // Thư viện Supabase đã tự thử lại khi máy chủ chưa trả lời, nên ở đây chỉ gọi một lần.
    let profile = null, err = null;
    try { profile = await loadProfile(); } catch (e) { err = e; }
    if (err) {
      const { data } = await sb.auth.getSession().catch(() => ({ data: {} }));
      if (!data || !data.session) return toLogin();
      document.body.innerHTML = `<div style="max-width:420px;margin:15vh auto;padding:24px;font-family:system-ui,sans-serif;text-align:center"><h1 style="font-size:20px">Chưa kết nối được máy chủ</h1><p style="color:#56635c">Phiên đăng nhập vẫn còn. Kiểm tra mạng rồi bấm Tải lại.</p><button onclick="location.reload()" style="padding:8px 16px;border-radius:8px;border:0;background:#0d7a62;color:#fff;font-weight:600;cursor:pointer">Tải lại</button></div>`;
      return new Promise(() => {});
    }
    if (!profile) return toLogin();
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

  // Đổi mật khẩu: kiểm tra mật khẩu hiện tại trước, rồi đặt mật khẩu mới. Trả về câu lỗi tiếng Việt hoặc "" nếu xong.
  async function changePassword(email, current, next) {
    const a = await sb.auth.signInWithPassword({ email, password: current });
    if (a.error) return /rate|too many/i.test(a.error.message) ? "Nhập sai nhiều lần. Đợi vài phút rồi thử lại." : "Mật khẩu hiện tại chưa đúng.";
    const b = await sb.auth.updateUser({ password: next, data: { must_change_pw: false } });
    if (!b.error) return "";
    const m = b.error.message || "";
    if (/different/i.test(m)) return "Mật khẩu mới phải khác mật khẩu hiện tại.";
    if (/weak|least|characters|strength/i.test(m)) return "Mật khẩu mới chưa đủ mạnh: dùng từ 8 ký tự, có cả chữ và số.";
    return "Chưa đổi được mật khẩu: " + m;
  }

  async function signOut() { if (sb) await sb.auth.signOut(); location.replace("login.html"); }

  window.Auth = { sb, configured, ROLES, VIEWS, ADMIN_TABS, SCOPES, DEFAULT_SCOPE, loadCatalog, loadProfile, requireAuth, callFn, changePassword, signOut };
})();
