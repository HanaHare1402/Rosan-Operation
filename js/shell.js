// Khung chung cho mọi trang sau đăng nhập: thanh điều hướng (Báo cáo / Quản trị), thẻ người dùng,
// đổi giao diện sáng/tối, menu trượt trên điện thoại.
(function () {
  // Áp giao diện đã chọn ngay khi tải để không nháy màu.
  const THEME_KEY = "tv_theme";
  const getTheme = () => { try { return localStorage.getItem(THEME_KEY) || "auto"; } catch (e) { return "auto"; } };
  const applyTheme = (t) => { if (t === "auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.setAttribute("data-theme", t); };
  applyTheme(getTheme());

  // Biểu tượng nét mảnh, 24×24.
  const P = {
    home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/><path d="M10 21v-6h4v6"/>',
    users: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5"/><circle cx="17" cy="9" r="2.6"/><path d="M15.5 14.6c2.9-.3 5.5 1.6 5.5 4.9"/>',
    user: '<circle cx="12" cy="8" r="3.6"/><path d="M4.5 20.5c0-3.9 3.4-6.5 7.5-6.5s7.5 2.6 7.5 6.5"/>',
    box: '<path d="m3.5 7.5 8.5-4.5 8.5 4.5v9L12 21l-8.5-4.5z"/><path d="m3.5 7.5 8.5 4.5 8.5-4.5"/><path d="M12 12v9"/>',
    receipt: '<path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6M9 16h3"/>',
    chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
    bell: '<path d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
    folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.5h8.5A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"/>',
    alert: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16.5v.01"/>',
    coins: '<ellipse cx="9" cy="7" rx="6" ry="3"/><path d="M3 7v5c0 1.7 2.7 3 6 3s6-1.3 6-3V7"/><path d="M15 10.5c3.3 0 6 1.3 6 3s-2.7 3-6 3c-1.2 0-2.3-.2-3.2-.5"/><path d="M21 13.5v4c0 1.7-2.7 3-6 3s-6-1.3-6-3v-1"/>',
    plug: '<path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/>',
    shield: '<path d="M12 3 4.5 6v5.5c0 4.6 3.2 8.2 7.5 9.5 4.3-1.3 7.5-4.9 7.5-9.5V6z"/><path d="m9 12 2.2 2.2L15.5 10"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    logout: '<path d="M15 4h3.5A1.5 1.5 0 0 1 20 5.5v13a1.5 1.5 0 0 1-1.5 1.5H15"/><path d="M10 16.5 14.5 12 10 7.5M14.5 12H4"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
    auto: '<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17a8.5 8.5 0 0 0 0-17z" fill="currentColor" stroke="none"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    refresh: '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8"/><path d="M4 3.5V8h4.5"/><path d="M4 13a8 8 0 0 0 14.3 4.9L20 16"/><path d="M20 20.5V16h-4.5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    inbox: '<path d="M3 13.5 5.5 5h13L21 13.5V19a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z"/><path d="M3 13.5h5l1.5 2.5h5l1.5-2.5h5"/>',
    lock: '<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    compare: '<path d="M7 4 3 8l4 4"/><path d="M3 8h13"/><path d="m17 20 4-4-4-4"/><path d="M21 16H8"/>',
    x: '<path d="M6 6l12 12M18 6 6 18"/>',
    target: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r=".8"/>',
    pen: '<path d="M4 20h4L19.5 8.5a2.1 2.1 0 0 0-4-4L4 16z"/><path d="m14 6 4 4"/>',
    tag: '<path d="M3.5 12.5V4.5a1 1 0 0 1 1-1h8l8 8-9 9z"/><circle cx="8" cy="8" r="1.4"/>',
  };
  const icon = (n, extra) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"${extra || ""}>${P[n] || ""}</svg>`;

  const REPORT = [
    ["tongquan", "Tổng quan", "home"], ["team", "Team", "users"], ["nhansu", "Nhân sự", "user"], ["sanpham", "Sản phẩm", "box"],
    ["donhang", "Đơn hàng", "receipt"], ["kqkd", "Kết quả kinh doanh", "chart"], ["kpi", "KPI", "target"], ["chiphi", "Chi phí ads", "pen"], ["canhbao", "Cảnh báo", "bell", "alertCnt"], ["caidat", "Cài đặt", "settings"],
  ];
  const ADMIN = [
    ["danhmuc", "Danh mục", "folder"], ["chuakhaibao", "Chưa khai báo", "alert", "unmappedCnt"], ["giavon", "Giá vốn", "coins"], ["nhomsp", "Nhóm sản phẩm", "tag"],
    ["pos", "Kết nối POS", "plug"], ["taikhoan", "Tài khoản", "shield"], ["nhatky", "Nhật ký đồng bộ", "list"],
  ];

  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const initials = (n) => String(n || "?").trim().split(/\s+/).slice(-2).map((w) => w[0]).join("").toUpperCase();

  // page: "index" hoặc "admin". Trả về phần tử <aside> đã dựng.
  function render(me, page) {
    const app = document.querySelector(".app"), aside = app.querySelector("aside");
    const views = (window.Auth && Auth.VIEWS[me.role]) || [];
    const adminTabs = ADMIN.filter(([k]) => (Auth.ADMIN_TABS[k] || []).includes(me.role));
    const link = (k, label, ic, cnt, isAdmin) => {
      const here = isAdmin ? page === "admin" : page === "index";
      const href = (here ? "" : isAdmin ? "admin.html" : "index.html") + "#" + k;
      const data = here ? (isAdmin ? ` data-tab="${k}"` : ` data-v="${k}"`) : "";
      return `<a href="${href}"${data} title="${esc(label)}">${icon(ic)}<span class="lbl">${esc(label)}</span>${cnt ? `<span class="cnt" id="${cnt}"></span>` : ""}</a>`;
    };
    aside.innerHTML = `
      <div class="brand-row"><img class="logo logo-img" src="img/rosan-mark.png" width="34" height="34" alt=""><div><div class="brand">Rosan Operation</div><div class="brand-sub">Vận hành - Rosan</div></div></div>
      <nav id="nav" aria-label="Điều hướng chính">
        ${views.length ? `<div class="nav-group">Báo cáo</div>` + REPORT.filter(([k]) => views.includes(k)).map(([k, l, i, c]) => link(k, l, i, c, false)).join("") : ""}
        ${adminTabs.length ? `<div class="nav-group">Quản trị</div>` + adminTabs.map(([k, l, i, c]) => link(k, l, i, c, true)).join("") : ""}
      </nav>
      <div class="side-foot" id="sideFoot"></div>
      <div class="userbox">
        <div class="avatar">${esc(initials(me.full_name || me.email))}</div>
        <div class="meta"><div class="who" id="who">${esc(me.full_name || me.email)}</div><div class="role" id="whoRole">${esc(Auth.ROLES[me.role] || "Chưa có vai trò")}${me.scope && Auth.SCOPES[me.scope] ? " · " + esc(Auth.SCOPES[me.scope]) : ""}</div></div>
        <button class="icon-btn" id="pwBtn" type="button" title="Đổi mật khẩu" aria-label="Đổi mật khẩu">${icon("lock")}</button>
        <button class="icon-btn" id="themeBtn" type="button"></button>
        <button class="icon-btn" id="logout" type="button" title="Đăng xuất" aria-label="Đăng xuất">${icon("logout")}</button>
      </div>`;
    // Nút menu trên điện thoại + lớp phủ.
    if (!app.querySelector(".scrim")) app.insertAdjacentHTML("beforeend", '<div class="scrim"></div>');
    const main = app.querySelector("main");
    if (!main.querySelector(".mtop")) main.insertAdjacentHTML("afterbegin", `<div class="mtop"><button class="icon-btn" id="menuBtn" type="button" aria-label="Mở menu">${icon("menu")}</button><img class="logo logo-img" src="img/rosan-mark.png" width="28" height="28" alt="" style="width:28px;height:28px"><div class="brand">Rosan Operation</div></div>`);
    const close = () => app.classList.remove("nav-open");
    main.querySelector("#menuBtn").onclick = () => app.classList.add("nav-open");
    app.querySelector(".scrim").onclick = close;
    aside.addEventListener("click", (e) => { if (e.target.closest("nav a")) close(); });
    aside.querySelector("#logout").onclick = () => Auth.signOut();
    ME = me;
    aside.querySelector("#pwBtn").onclick = () => pwDialog(false);
    // Mật khẩu do quản trị viên cấp: bắt đổi sang mật khẩu riêng trước khi dùng tiếp.
    if (me.must_change_pw) pwDialog(true);
    const tb = aside.querySelector("#themeBtn");
    const LABEL = { auto: "Giao diện: theo máy", light: "Giao diện: sáng", dark: "Giao diện: tối" };
    const paint = () => { const t = getTheme(); tb.innerHTML = icon(t === "dark" ? "moon" : t === "light" ? "sun" : "auto"); tb.title = LABEL[t] + " (bấm để đổi)"; tb.setAttribute("aria-label", LABEL[t]); };
    tb.onclick = () => { const order = ["auto", "light", "dark"]; const n = order[(order.indexOf(getTheme()) + 1) % 3]; try { localStorage.setItem(THEME_KEY, n); } catch (e) {} applyTheme(n); paint(); };
    paint();
    // Bóng mờ dưới phần đầu trang khi đã cuộn xuống, cho biết nội dung đang trượt bên dưới.
    const sh = document.querySelector(".stickhead");
    if (sh) { const onS = () => sh.classList.toggle("scrolled", window.scrollY > 4); window.addEventListener("scroll", onS, { passive: true }); onS(); }
    // Chiều cao phần đầu trang cố định: khung bảng cuộn riêng (VD báo cáo KQKD) vừa đúng phần màn hình còn lại.
    if (sh) {
      const setH = () => {
        const fixed = getComputedStyle(sh).position === "sticky" ? sh.offsetHeight : 0;
        const mt = document.querySelector(".mtop"), mh = mt && getComputedStyle(mt).display !== "none" ? mt.offsetHeight : 0;
        document.documentElement.style.setProperty("--sh", fixed + "px");
        // --sht: chỗ để hàng tiêu đề bảng dính vào (dưới đầu trang cố định, hoặc dưới thanh trên cùng trên điện thoại).
        document.documentElement.style.setProperty("--sht", Math.max(fixed, mh) + "px");
      };
      setH(); if (window.ResizeObserver) new ResizeObserver(setH).observe(sh); window.addEventListener("resize", setH);
    }
    return aside;
  }

  // ---------- đổi mật khẩu ----------
  let ME = null;
  const EYE = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/><path class="slash" d="M4 4l16 16"/></svg>';
  const pwField = (id, label, ac) => `<label>${label}<span class="inwrap">${icon("lock", ' class="inico" width="16" height="16"')}<input id="${id}" type="password" autocomplete="${ac}" required><button class="pweye" type="button" aria-label="Hiện mật khẩu" aria-pressed="false" title="Hiện mật khẩu">${EYE}</button></span></label>`;
  const PW_RULES = [
    ["len", "Ít nhất 8 ký tự", (c, n) => n.length >= 8],
    ["mix", "Có cả chữ và số", (c, n) => /[A-Za-zÀ-ỹ]/.test(n) && /\d/.test(n)],
    ["diff", "Khác mật khẩu hiện tại", (c, n) => !!n && n !== c],
    ["same", "Hai ô mật khẩu mới giống nhau", (c, n, r) => !!n && n === r],
  ];
  function pwDialog(forced) {
    if (!ME || document.querySelector("dialog.pwdlg")) return;
    const d = document.createElement("dialog");
    d.className = "pwdlg";
    d.setAttribute("aria-labelledby", "pwT");
    d.innerHTML = `<form id="pwForm" novalidate>
      <div class="pwhead"><span class="pwico" aria-hidden="true">${icon("lock")}</span><div><h2 id="pwT">${forced ? "Đặt mật khẩu của riêng bạn" : "Đổi mật khẩu"}</h2>
        <p class="hint keep">${forced ? "Mật khẩu hiện tại do quản trị viên cấp. Hãy đổi sang mật khẩu chỉ bạn biết để tiếp tục sử dụng." : "Tài khoản " + esc(ME.login_email || ME.email || "") + "."}</p></div>
        ${forced ? "" : `<button class="icon-btn" type="button" data-pwclose aria-label="Đóng">${icon("x")}</button>`}</div>
      ${pwField("pwCur", forced ? "Mật khẩu được cấp" : "Mật khẩu hiện tại", "current-password")}
      ${pwField("pwNew", "Mật khẩu mới", "new-password")}
      ${pwField("pwRep", "Nhập lại mật khẩu mới", "new-password")}
      <ul class="pwrules" aria-label="Yêu cầu mật khẩu">${PW_RULES.map(([k, t]) => `<li data-r="${k}"><span class="pwchk" aria-hidden="true">${icon("check")}</span><span>${t}</span><span class="sr"> – chưa đạt</span></li>`).join("")}</ul>
      <div class="msg" id="pwMsg" role="status" aria-live="polite"></div>
      <div class="pwfoot">${forced ? '<button class="lnk" type="button" data-pwout>Đăng xuất</button>' : '<button class="btn ghost" type="button" data-pwclose>Huỷ</button>'}<button class="btn" type="submit" id="pwSave">Lưu mật khẩu mới</button></div>
    </form>`;
    document.body.appendChild(d);
    const $ = (s) => d.querySelector(s), msg = (t, cls) => { $("#pwMsg").className = "msg" + (cls ? " " + cls : ""); $("#pwMsg").textContent = t; };
    const check = () => {
      const c = $("#pwCur").value, n = $("#pwNew").value, r = $("#pwRep").value;
      let ok = true;
      PW_RULES.forEach(([k, , f]) => { const v = f(c, n, r), li = d.querySelector(`[data-r="${k}"]`); li.classList.toggle("ok", v); li.querySelector(".sr").textContent = v ? " – đã đạt" : " – chưa đạt"; ok = ok && v; });
      return ok;
    };
    const close = () => { d.close(); d.remove(); };
    d.addEventListener("input", () => { check(); if ($("#pwMsg").textContent) msg(""); });
    d.addEventListener("cancel", (e) => { if (forced) e.preventDefault(); else { e.preventDefault(); close(); } });
    d.addEventListener("click", (e) => {
      const eye = e.target.closest(".pweye");
      if (eye) { const inp = eye.parentElement.querySelector("input"), on = inp.type === "password"; inp.type = on ? "text" : "password"; eye.setAttribute("aria-pressed", String(on)); const l = on ? "Ẩn mật khẩu" : "Hiện mật khẩu"; eye.setAttribute("aria-label", l); eye.title = l; return; }
      if (e.target.closest("[data-pwclose]")) close();
      if (e.target.closest("[data-pwout]")) Auth.signOut();
    });
    $("#pwForm").addEventListener("submit", async (e) => {
      e.preventDefault();
      if (!$("#pwCur").value) { msg("Nhập mật khẩu " + (forced ? "được cấp" : "hiện tại") + ".", "neg"); $("#pwCur").focus(); return; }
      if (!check()) { const bad = PW_RULES.find(([k]) => !d.querySelector(`[data-r="${k}"]`).classList.contains("ok")); msg("Mật khẩu mới chưa đạt: " + bad[1].toLowerCase() + ".", "neg"); $("#pwNew").focus(); return; }
      const btn = $("#pwSave"); btn.disabled = true; btn.textContent = "Đang lưu…";
      const err = await Auth.changePassword(ME.login_email || ME.email, $("#pwCur").value, $("#pwNew").value).catch((x) => "Chưa đổi được mật khẩu: " + (x.message || x));
      btn.disabled = false; btn.textContent = "Lưu mật khẩu mới";
      if (err) { msg(err, "neg"); return; }
      ME.must_change_pw = false; close();
      toast("Đã đổi mật khẩu. Lần đăng nhập sau dùng mật khẩu mới.");
    });
    d.showModal();
    check();
    $("#pwCur").focus();
  }

  // Số trên huy hiệu menu; 0 thì ẩn.
  function badge(id, n) { const el = document.getElementById(id); if (!el) return; el.textContent = n ? String(n) : ""; }

  // Khối trống có biểu tượng, tiêu đề, mô tả, nút.
  function empty(ic, title, text, actions) {
    return `<div class="empty"><div class="ico">${icon(ic)}</div><h3>${title}</h3>${text ? `<p>${text}</p>` : ""}${actions ? `<div class="act">${actions}</div>` : ""}</div>`;
  }

  // Menu "⋯": bấm ra ngoài hoặc chọn một mục thì đóng.
  document.addEventListener("click", (e) => {
    if (!e.target.isConnected) return; // bảng vừa được vẽ lại (VD bấm "Xoá" lần đầu): giữ menu mới
    document.querySelectorAll("details.more[open]").forEach((d) => {
      if (!d.contains(e.target) || e.target.closest(".menu button")) d.removeAttribute("open");
    });
  });

  // Thông báo nổi ở đáy màn hình, tự ẩn; có nút "Hoàn tác" nếu truyền undo.
  function toast(msg, o = {}) {
    let box = document.querySelector(".toasts");
    if (!box) { box = document.createElement("div"); box.className = "toasts"; box.setAttribute("role", "status"); box.setAttribute("aria-live", "polite"); document.body.appendChild(box); }
    const t = document.createElement("div");
    t.className = "toast" + (o.err ? " err" : "");
    t.innerHTML = `<span>${esc(msg)}</span>${o.undo ? '<button type="button">Hoàn tác</button>' : ""}`;
    box.appendChild(t);
    const done = () => t.remove();
    const timer = setTimeout(done, o.ms || (o.undo ? 7000 : 4000));
    if (o.undo) t.querySelector("button").onclick = () => { clearTimeout(timer); done(); o.undo(); };
  }

  // Hàng tiêu đề bảng (table.sthead) dính ngay dưới phần đầu trang cố định khi cuộn.
  // Bảng nằm trong khung cuộn ngang (.tw) nên position:sticky của <thead> không bám theo trang được:
  // đo độ rộng từng cột, cố định cột bằng <colgroup>, rồi chép hàng tiêu đề ra một khung riêng (.fh) đặt
  // trước bảng — khung này sticky thật (trình duyệt tự giữ, không giật). Kéo ngang thân bảng thì khung tiêu đề kéo theo.
  function fixHeads() {
    document.querySelectorAll("table.sthead:not([data-fh])").forEach((t) => {
      const tw = t.parentElement, head = t.tHead;
      if (!tw || !tw.classList.contains("tw") || !head || !t.offsetWidth) return;
      t.setAttribute("data-fh", "1");
      const cells = [...head.rows[0].cells], ws = cells.map((c) => Math.ceil(c.getBoundingClientRect().width));
      const sum = ws.reduce((a, b) => a + b, 0);
      const cg = '<colgroup>' + ws.map((w) => `<col style="width:${w}px">`).join("") + "</colgroup>";
      t.insertAdjacentHTML("afterbegin", cg);
      t.style.tableLayout = "fixed"; t.style.minWidth = sum + "px";
      const clone = t.cloneNode(false); if (t.id) clone.id = t.id + "h"; clone.removeAttribute("data-fh"); clone.classList.remove("sthead");
      clone.innerHTML = cg + head.outerHTML;
      const fh = document.createElement("div"); fh.className = "fh"; fh.setAttribute("aria-hidden", "true"); fh.appendChild(clone);
      head.style.display = "none";
      tw.classList.add("fhb"); tw.before(fh);
    });
  }
  // Dòng hướng dẫn dưới tiêu đề (p.hint ngay sau h2/h3) thu gọn thành nút (?) cạnh tiêu đề: chạm / rê chuột mới hiện.
  // Dòng là số liệu đánh dấu .keep, dòng kết quả có id (VD tóm tắt file vừa đọc) giữ nguyên.
  function hintsToTips() {
    document.querySelectorAll("p.hint:not(.keep):not([id])").forEach((p) => {
      const h = p.previousElementSibling;
      const txt = p.textContent.replace(/\s+/g, " ").trim();
      const t = document.createElement("span");
      t.className = "tip"; t.tabIndex = 0; t.setAttribute("role", "note"); t.setAttribute("aria-label", txt); t.dataset.tip = txt; t.textContent = "?";
      if (h && (/^H[1-3]$/.test(h.tagName) || h.classList.contains("edtitle"))) { if (txt) h.append(" ", t); p.remove(); return; }
      // Dòng hướng dẫn nằm giữa form: thay bằng một dòng nhỏ "Hướng dẫn (?)".
      if (!txt) { p.remove(); return; }
      const d = document.createElement("div"); d.className = "hintq"; d.append("Hướng dẫn ", t); p.replaceWith(d);
    });
  }
  new MutationObserver(() => { hintsToTips(); requestAnimationFrame(fixHeads); }).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener("DOMContentLoaded", hintsToTips);
  // Kéo ngang thân bảng thì hàng tiêu đề tách riêng kéo theo.
  document.addEventListener("scroll", (e) => { const t = e.target; if (t.classList && t.classList.contains("fhb")) { const h = t.previousElementSibling; if (h && h.classList.contains("fh")) h.scrollLeft = t.scrollLeft; } }, true);

  // Lời giải thích của nút (?): vẽ ở một lớp riêng gắn vào <body>, vị trí cố định theo màn hình,
  // nên không bị bảng (vùng cuộn ngang, tiêu đề cố định) che hay cắt. Rê chuột, Tab tới hoặc chạm để xem; Esc để tắt.
  const tipBox = document.createElement("div");
  tipBox.className = "tipbox"; tipBox.id = "tipbox"; tipBox.setAttribute("role", "tooltip"); tipBox.hidden = true;
  let tipOn = null;
  function showTip(t) {
    const txt = t.dataset.tip || t.getAttribute("aria-label") || "";
    if (!txt) return;
    if (!tipBox.isConnected) document.body.appendChild(tipBox);
    tipOn = t; tipBox.textContent = txt; tipBox.hidden = false; tipBox.style.left = "0px"; tipBox.style.top = "0px";
    t.setAttribute("aria-describedby", "tipbox");
    const r = t.getBoundingClientRect(), b = tipBox.getBoundingClientRect(), gap = 8, vw = document.documentElement.clientWidth;
    let x = r.left + r.width / 2 - b.width / 2;
    x = Math.max(8, Math.min(x, vw - b.width - 8));
    const above = r.top - b.height - gap >= 8;
    tipBox.style.left = Math.round(x) + "px";
    tipBox.style.top = Math.round(above ? r.top - b.height - gap : r.bottom + gap) + "px";
    tipBox.dataset.side = above ? "top" : "bottom";
    tipBox.style.setProperty("--ax", Math.round(r.left + r.width / 2 - x) + "px");
  }
  function hideTip() { if (tipOn) tipOn.removeAttribute("aria-describedby"); tipOn = null; tipBox.hidden = true; }
  document.addEventListener("mouseover", (e) => { const t = e.target.closest && e.target.closest(".tip"); if (t && t !== tipOn) showTip(t); });
  document.addEventListener("mouseout", (e) => { const t = e.target.closest && e.target.closest(".tip"); if (t && t === tipOn && !t.contains(e.relatedTarget) && document.activeElement !== t) hideTip(); });
  document.addEventListener("focusin", (e) => { const t = e.target.closest && e.target.closest(".tip"); if (t) showTip(t); else if (tipOn) hideTip(); });
  document.addEventListener("focusout", (e) => { if (tipOn && e.target === tipOn) hideTip(); });
  document.addEventListener("click", (e) => { const t = e.target.closest && e.target.closest(".tip"); if (t) { e.stopPropagation(); if (tipOn === t && e.pointerType !== "mouse") hideTip(); else showTip(t); } else if (tipOn) hideTip(); }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && tipOn) hideTip(); });
  // Cuộn trang / bảng: lời giải thích đi theo nút (?); nút ra khỏi màn hình thì tắt.
  const followTip = () => { if (!tipOn) return; const r = tipOn.getBoundingClientRect(); if (!tipOn.isConnected || r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) hideTip(); else showTip(tipOn); };
  window.addEventListener("scroll", followTip, true);
  window.addEventListener("resize", followTip);

  window.Shell = { render, icon, badge, empty, toast, fixHeads };
})();
