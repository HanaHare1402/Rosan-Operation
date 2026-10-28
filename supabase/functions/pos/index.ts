// Kết nối Pancake POS. API key chỉ được đọc ở đây (từ Vault, qua service role), không bao giờ trả về trình duyệt.
//   action "test"   (admin)            : thử key của một shop, trả về danh sách kho và tổng số đơn
//   action "sample" (admin)            : trả 1 đơn mới nhất dạng thô để xem POS có những trường gì
//   action "sync"   (admin, quản lý, cron): kéo đơn mới/vừa cập nhật về bảng orders
//   action "refresh"(mọi tài khoản có vai trò): gọi khi mở trang, kéo nhanh phần mới nhất của các shop đã đồng bộ xong
import { adminClient, cors, getCaller, json } from "../_shared/common.ts";

const POS = "https://pos.pages.fm/api/v1";
const PAGE_SIZE = 100;
const PARALLEL = 8; // số trang gọi POS cùng lúc (POS cho 1000 lượt/phút; 8 trang × ~1–2 giây ≈ 250–500 lượt/phút)
const WRITE_CHUNK = 250; // số đơn mỗi lần ghi vào Supabase
const TIME_BUDGET_MS = 110_000; // dừng sớm, lần chạy sau làm tiếp từ trang đang dở
const OVERLAP_MS = 10 * 60_000; // lùi 10 phút mỗi lần để không sót đơn cập nhật sát mốc
const REFRESH_BUDGET_MS = 25_000; // người dùng đang chờ trên trang
const REFRESH_MIN_GAP_MS = 30_000; // vừa kéo trong 30 giây thì dùng luôn, không gọi POS nữa

type Shop = {
  id: string; name: string; pos_shop_id: string; active: boolean; api_key_secret_id: string | null;
  last_synced_at: string | null; sync_window_start: string | null; sync_window_end: string | null; sync_page: number | null;
  sync_total: number | null;
};

async function posGet(path: string, key: string, params: Record<string, string | number> = {}) {
  const u = new URL(POS + path);
  u.searchParams.set("api_key", key);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, String(v));
  for (let attempt = 0; attempt < 3; attempt++) {
    const r = await fetch(u, { headers: { Accept: "application/json" } });
    if (r.status === 429) { await new Promise((s) => setTimeout(s, 2000 * (attempt + 1))); continue; }
    const text = await r.text();
    let body: any;
    try { body = JSON.parse(text); } catch { throw new Error(`POS trả về không phải JSON (HTTP ${r.status}): ${text.slice(0, 200)}`); }
    if (!r.ok || body?.success === false) throw new Error(`POS lỗi HTTP ${r.status}: ${body?.message || body?.error || text.slice(0, 200)}`);
    return body;
  }
  throw new Error("POS báo quá nhiều yêu cầu (429), thử lại sau");
}

// POS có thể trả giờ không kèm múi giờ; coi là UTC.
function ts(v: unknown): string | null {
  if (v == null || v === "") return null;
  if (typeof v === "number") return new Date(v < 1e12 ? v * 1000 : v).toISOString();
  const s = String(v);
  const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : s + "Z");
  return isNaN(+d) ? null : d.toISOString();
}
const num = (v: unknown) => (v == null || v === "" || isNaN(Number(v)) ? null : Number(v));

// Tên trường lấy theo webhook và tài liệu cộng đồng của POS; cột raw giữ nguyên đơn gốc để chỉnh sau.
function mapOrder(shopId: string, o: any) {
  const items = Array.isArray(o.items) ? o.items.map((i: any) => ({
    name: i.variation_info?.name ?? i.product_name ?? i.name ?? null,
    code: i.variation_info?.product_display_id || i.variation_info?.display_id || i.product_display_id || null,
    product_id: i.product_id ?? null,
    variation_id: i.variation_id ?? null,
    quantity: num(i.quantity),
    price: num(i.variation_info?.retail_price ?? i.retail_price),
  })) : null;
  const addr = o.shipping_address || {};
  return {
    shop_id: shopId,
    pos_order_id: String(o.id ?? o.system_id),
    status: num(o.status),
    status_name: o.status_name ?? null,
    inserted_at: ts(o.inserted_at),
    updated_at: ts(o.updated_at),
    total_price: num(o.total_price_after_sub_discount ?? o.total_price),
    cod: num(o.cod),
    shipping_fee: num(o.shipping_fee),
    bill_full_name: o.bill_full_name ?? null,
    bill_phone_number: o.bill_phone_number ?? null,
    province: addr.province_name ?? addr.province_id ?? null,
    tracking: o.partner?.extend_code ?? o.partner?.tracking_code ?? null,
    warehouse: o.warehouse_info?.name ?? (o.warehouse_id != null ? String(o.warehouse_id) : null),
    seller: o.assigning_seller?.name ?? o.marketer?.name ?? (o.assigning_seller_id != null ? String(o.assigning_seller_id) : null),
    items,
    raw: o,
    synced_at: new Date().toISOString(),
  };
}

async function syncShop(sb: ReturnType<typeof adminClient>, shop: Shop, trigger: string, deadline: number) {
  // Lượt khác đang kéo shop này thì bỏ qua, tránh hai lượt ghi chồng nhau.
  const { data: locked, error: le } = await sb.rpc("internal_lock_shop", { p_shop: shop.id });
  if (le) return { shop: shop.name, status: "error", pages: 0, orders: 0, error: "Chưa chạy SQL 20261024010000_sync_lock.sql trên Supabase: " + le.message };
  if (locked !== true) return { shop: shop.name, status: "busy", pages: 0, orders: 0, error: null };
  const { data: run } = await sb.from("sync_runs").insert({ shop_id: shop.id, trigger, status: "running" }).select("id").single();
  let pages = 0, count = 0;
  const finish = async (patch: Record<string, unknown>, status: string, error: string | null) => {
    await sb.from("pos_shops").update({ ...patch, sync_lock_at: null, last_sync_status: status, last_sync_error: error, last_sync_count: count }).eq("id", shop.id);
    if (run) await sb.from("sync_runs").update({ finished_at: new Date().toISOString(), pages, orders: count, status, error }).eq("id", run.id);
    return { shop: shop.name, status, pages, orders: count, error };
  };
  try {
    if (!shop.pos_shop_id) throw new Error("Chưa điền Shop ID POS");
    const { data: key, error: ke } = await sb.rpc("internal_get_pos_key", { p_shop: shop.id });
    if (ke) throw ke;
    if (!key) throw new Error("Chưa có API key");

    // Tiếp tục cửa sổ đang dở, hoặc mở cửa sổ mới từ lần đồng bộ trước (lùi một chút) đến bây giờ.
    // Mốc đồng bộ admin chọn (Quản trị → Kết nối POS): đơn tạo trước mốc thì không kéo, không giữ.
    const { data: cut, error: ce } = await sb.rpc("sync_cutoff", { p_shop: shop.id });
    if (ce) throw new Error("Chưa chạy SQL 20261025020000_sync_range.sql trên Supabase: " + ce.message);
    const cutoff = new Date(cut as string);
    const start = shop.sync_window_start ? new Date(shop.sync_window_start)
      : shop.last_synced_at ? new Date(Math.max(+new Date(shop.last_synced_at) - OVERLAP_MS, +cutoff))
      : cutoff;
    const end = shop.sync_window_end ? new Date(shop.sync_window_end) : new Date();
    // Lùi một trang khi làm tiếp: đơn được cập nhật trong lúc chạy có thể làm các trang dịch đi.
    let page = Math.max(1, (shop.sync_page ?? 1) - (shop.sync_page ? 1 : 0));
    // Lần đầu (chưa đồng bộ xong lần nào): lọc theo NGÀY TẠO trong [mốc, end], chỉ đơn trong khoảng, không phí
    // thời gian vào đơn cũ vừa đổi trạng thái. Sau đó: lọc theo ngày cập nhật để bắt đơn đổi trạng thái.
    const backfill = !shop.last_synced_at;
    // include_removed=1: lấy cả đơn đã xoá trên POS để web đánh dấu "Đã xoá" (mặc định POS ẩn đơn đã xoá).
    const params: Record<string, string | number> = backfill
      ? { updateStatus: "inserted_at", startDateTime: Math.floor(+start / 1000), endDateTime: Math.floor(+end / 1000), include_removed: 1 }
      : { updateStatus: "updated_at", startDateTime: Math.floor(+start / 1000), endDateTime: Math.floor(+end / 1000), option_sort: "last_updated_order_asc", include_removed: 1 };
    let total: number | null = shop.sync_window_start ? (shop.sync_total ?? null) : null, totalPages = 0;

    // Chạy song song: trong lúc ghi nhóm trang trước vào Supabase thì đã tải nhóm trang sau từ POS.
    // Chỉ một lượt ghi chạy cùng lúc; tiến độ (sync_page) chỉ ghi sau khi đơn của các trang đó đã lưu xong,
    // nên dừng giữa chừng thì lần sau làm tiếp đúng chỗ, không sót trang.
    let safePage = page;
    let writing: Promise<void> = Promise.resolve();
    const writeBatch = (rows: ReturnType<typeof mapOrder>[], nextPage: number) => {
      writing = (async () => {
        for (let i = 0; i < rows.length; i += WRITE_CHUNK) {
          const { error } = await sb.from("orders").upsert(rows.slice(i, i + WRITE_CHUNK), { onConflict: "shop_id,pos_order_id" });
          if (error) throw error;
        }
        count += rows.length;
        safePage = nextPage;
        // Ghi tiến độ để trang Quản trị hiện thanh tiến độ.
        await sb.from("pos_shops").update({
          sync_total: total, sync_done: Math.min(total ?? Infinity, (nextPage - 1) * PAGE_SIZE),
          sync_window_start: start.toISOString(), sync_window_end: end.toISOString(), sync_page: nextPage,
        }).eq("id", shop.id);
      })();
      writing.catch(() => {}); // lỗi được báo khi chờ lượt ghi (await writing) bên dưới
    };

    while (true) {
      if (Date.now() > deadline) {
        await writing;
        return await finish({ sync_window_start: start.toISOString(), sync_window_end: end.toISOString(), sync_page: safePage }, "partial", null);
      }
      // Gọi vài trang song song; trang vượt quá cuối danh sách trả về rỗng, không sao.
      const n = totalPages ? Math.max(1, Math.min(PARALLEL, totalPages - page + 1)) : (page === 1 ? 1 : PARALLEL);
      const batch = await Promise.all(Array.from({ length: n }, (_, i) =>
        posGet(`/shops/${encodeURIComponent(shop.pos_shop_id)}/orders`, key, { page_number: page + i, page_size: PAGE_SIZE, ...params })));
      let stop = false, last = page;
      const rows: ReturnType<typeof mapOrder>[] = [];
      for (let i = 0; i < batch.length; i++) {
        const body = batch[i];
        const list: any[] = Array.isArray(body.data) ? body.data : Array.isArray(body.orders) ? body.orders : [];
        pages++; last = page + i;
        totalPages = Number(body.total_pages) || totalPages;
        total = Number(body.total_entries) || total;
        // Lọc theo ngày tạo: đơn cũ vừa đổi trạng thái vẫn nằm trong danh sách "vừa cập nhật".
        for (const o of list) {
          if (o && (o.id ?? o.system_id) != null && !(ts(o.inserted_at) && new Date(ts(o.inserted_at)!) < cutoff)) rows.push(mapOrder(shop.id, o));
        }
        if (!list.length || (totalPages ? last >= totalPages : list.length < PAGE_SIZE)) { stop = true; break; }
      }
      await writing;            // lượt ghi trước phải xong (và không lỗi) rồi mới ghi tiếp
      writeBatch(rows, last + 1);
      if (stop) break;
      page = last + 1;
    }
    await writing;
    return await finish({ last_synced_at: end.toISOString(), sync_window_start: null, sync_window_end: null, sync_page: null, sync_done: total ?? count, sync_total: total }, "ok", null);
  } catch (e) {
    return await finish({}, "error", (e as Error).message || String(e));
  }
}

// Tính lại phân bổ đơn (sau khi sửa nhân sự / kênh / team) theo từng đợt cho tới khi hết giờ.
async function drainRecompute(sb: ReturnType<typeof adminClient>, until: number) {
  let total = 0;
  while (Date.now() < until - 5000) {
    const { data, error } = await sb.rpc("recompute_batch", { p_limit: 5000 });
    if (error || !data?.[0]) break; // chưa chạy SQL 20261025040000_recompute_batches.sql
    total += Number(data[0].done) || 0;
    if (!Number(data[0].remaining)) break;
  }
  return total;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Chỉ nhận POST" }, 405);
  const deadline = Date.now() + TIME_BUDGET_MS;
  const sb = adminClient();

  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* body rỗng */ }

  // Người gọi: lịch đồng bộ (mã bí mật) hoặc người dùng đã đăng nhập.
  const cronSecret = req.headers.get("x-cron-secret") || "";
  let trigger = "cron", role: string | null = null;
  if (cronSecret) {
    const { data: ok } = await sb.rpc("internal_check_cron_secret", { p_secret: cronSecret });
    if (!ok) return json({ error: "Sai mã cron" }, 401);
    if (body.action !== "sync") return json({ error: "Lịch chỉ được gọi sync" }, 403);
  } else {
    const caller = await getCaller(req, sb);
    if (!caller) return json({ error: "Chưa đăng nhập" }, 401);
    role = caller.role;
    trigger = caller.email;
  }
  const isAdmin = role === "admin";

  try {
    if (body.action === "test" || body.action === "sample") {
      if (!isAdmin) return json({ error: "Chỉ admin" }, 403);
      const { data: shop } = await sb.from("pos_shops").select("*").eq("id", body.shop).maybeSingle();
      if (!shop) return json({ error: "Không tìm thấy shop" }, 404);
      if (!shop.pos_shop_id) return json({ error: "Chưa điền Shop ID POS" }, 400);
      const { data: key } = await sb.rpc("internal_get_pos_key", { p_shop: shop.id });
      if (!key) return json({ error: "Shop chưa có API key" }, 400);
      const path = `/shops/${encodeURIComponent(shop.pos_shop_id)}`;
      if (body.action === "sample") {
        const o = await posGet(path + "/orders", key, { page_number: 1, page_size: 1 });
        return json({ ok: true, order: (o.data || o.orders || [])[0] ?? null, keys: Object.keys(o) });
      }
      const [wh, o] = await Promise.all([
        posGet(path + "/warehouses", key),
        posGet(path + "/orders", key, { page_number: 1, page_size: 1 }),
      ]);
      return json({
        ok: true,
        warehouses: (wh.data || []).map((w: any) => ({ id: w.id, name: w.name })),
        total_orders: o.total_entries ?? o.total ?? null,
      });
    }

    if (body.action === "sync") {
      if (trigger !== "cron" && !["admin", "quan_ly"].includes(role || "")) return json({ error: "Chỉ admin hoặc quản lý" }, 403);
      let q = sb.from("pos_shops").select("*").eq("active", true).not("api_key_secret_id", "is", null);
      if (body.shop) q = q.eq("id", body.shop);
      // Kéo lại từ mốc đồng bộ: một shop, hoặc tất cả (sau khi admin đổi khoảng đồng bộ).
      if (body.reset && isAdmin) {
        let r = sb.from("pos_shops").update({ last_synced_at: null, sync_window_start: null, sync_window_end: null, sync_page: null, sync_total: null, sync_done: null });
        r = body.shop ? r.eq("id", body.shop) : r.not("id", "is", null);
        await r;
      }
      // Shop lâu chưa đồng bộ nhất chạy trước, để shop lớn không chiếm hết thời gian của shop khác.
      const { data: shops, error } = await q.order("last_synced_at", { ascending: true, nullsFirst: true });
      if (error) throw error;
      const results = [];
      for (const s of shops as Shop[]) {
        if (Date.now() > deadline) { results.push({ shop: s.name, status: "skipped", error: "Hết thời gian, lần sau làm tiếp" }); continue; }
        results.push(await syncShop(sb, s, trigger, deadline));
      }
      // Lịch tự động dọn đơn cũ hơn mốc (nếu admin bật) và nhật ký cũ.
      let purged: number | null = null;
      if (trigger === "cron" || body.purge) {
        const { data } = await sb.rpc("purge_old_orders");
        purged = typeof data === "number" ? data : null;
      }
      const recomputed = await drainRecompute(sb, deadline + 20_000);
      return json({ ok: true, results, purged, recomputed });
    }

    if (body.action === "refresh") {
      if (!role) return json({ error: "Tài khoản chưa được cấp quyền" }, 403);
      const fresh = new Date(Date.now() - REFRESH_MIN_GAP_MS).toISOString();
      // Chỉ shop đã kéo xong lần đầu; shop đang kéo dở lịch sử để lịch tự động làm tiếp.
      const { data: shops, error } = await sb.from("pos_shops").select("*")
        .eq("active", true).not("api_key_secret_id", "is", null)
        .is("sync_window_start", null).not("last_synced_at", "is", null).lt("last_synced_at", fresh);
      if (error) throw error;
      const until = Date.now() + REFRESH_BUDGET_MS;
      const results = await Promise.all((shops as Shop[]).map((s) => syncShop(sb, s, "mở trang: " + trigger, until)));
      // Mốc dữ liệu = shop cũ nhất trong số shop đang bán và có key.
      const { data: all } = await sb.from("pos_shops").select("name, last_synced_at")
        .eq("active", true).not("api_key_secret_id", "is", null);
      const times = (all || []).map((x) => x.last_synced_at).filter(Boolean).sort();
      return json({ ok: true, shops: (all || []).length, synced_at: times[0] ?? null, results });
    }

    return json({ error: "action không hợp lệ" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message || String(e) }, 500);
  }
});
