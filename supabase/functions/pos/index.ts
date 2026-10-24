// Kết nối Pancake POS. API key chỉ được đọc ở đây (từ Vault, qua service role), không bao giờ trả về trình duyệt.
//   action "test"   (admin)            : thử key của một shop, trả về danh sách kho và tổng số đơn
//   action "sample" (admin)            : trả 1 đơn mới nhất dạng thô để xem POS có những trường gì
//   action "sync"   (admin, quản lý, cron): kéo đơn mới/vừa cập nhật về bảng orders
//   action "refresh"(mọi tài khoản có vai trò): gọi khi mở trang, kéo nhanh phần mới nhất của các shop đã đồng bộ xong
import { adminClient, cors, getCaller, json } from "../_shared/common.ts";

const POS = "https://pos.pages.fm/api/v1";
const PAGE_SIZE = 100;
const TIME_BUDGET_MS = 110_000; // dừng sớm, lần chạy sau làm tiếp từ trang đang dở
const OVERLAP_MS = 10 * 60_000; // lùi 10 phút mỗi lần để không sót đơn cập nhật sát mốc
const DEFAULT_BACKFILL_DAYS = 30;
const REFRESH_BUDGET_MS = 25_000; // người dùng đang chờ trên trang
const REFRESH_MIN_GAP_MS = 30_000; // vừa kéo trong 30 giây thì dùng luôn, không gọi POS nữa

type Shop = {
  id: string; name: string; pos_shop_id: string; active: boolean; api_key_secret_id: string | null;
  last_synced_at: string | null; sync_window_start: string | null; sync_window_end: string | null; sync_page: number | null;
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

async function syncShop(sb: ReturnType<typeof adminClient>, shop: Shop, trigger: string, deadline: number, backfillDays: number) {
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
    const start = shop.sync_window_start ? new Date(shop.sync_window_start)
      : shop.last_synced_at ? new Date(+new Date(shop.last_synced_at) - OVERLAP_MS)
      : new Date(Date.now() - backfillDays * 86400_000);
    const end = shop.sync_window_end ? new Date(shop.sync_window_end) : new Date();
    // Lùi một trang khi làm tiếp: đơn được cập nhật trong lúc chạy có thể làm các trang dịch đi.
    let page = Math.max(1, (shop.sync_page ?? 1) - (shop.sync_page ? 1 : 0));

    while (true) {
      if (Date.now() > deadline) {
        return await finish({ sync_window_start: start.toISOString(), sync_window_end: end.toISOString(), sync_page: page }, "partial", null);
      }
      const body = await posGet(`/shops/${encodeURIComponent(shop.pos_shop_id)}/orders`, key, {
        page_number: page, page_size: PAGE_SIZE, updateStatus: "updated_at",
        startDateTime: Math.floor(+start / 1000), endDateTime: Math.floor(+end / 1000), option_sort: "last_updated_order_asc",
      });
      const list: any[] = Array.isArray(body.data) ? body.data : Array.isArray(body.orders) ? body.orders : [];
      pages++;
      if (list.length) {
        const rows = list.filter((o) => o && (o.id ?? o.system_id) != null).map((o) => mapOrder(shop.id, o));
        const { error } = await sb.from("orders").upsert(rows, { onConflict: "shop_id,pos_order_id" });
        if (error) throw error;
        count += rows.length;
      }
      const totalPages = Number(body.total_pages) || 0;
      if (!list.length || list.length < PAGE_SIZE || (totalPages && page >= totalPages)) break;
      page++;
    }
    return await finish({ last_synced_at: end.toISOString(), sync_window_start: null, sync_window_end: null, sync_page: null }, "ok", null);
  } catch (e) {
    return await finish({}, "error", (e as Error).message || String(e));
  }
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
      // Kéo lại từ đầu (backfill_days ngày) cho shop được chọn.
      if (body.reset && body.shop && isAdmin) {
        await sb.from("pos_shops").update({ last_synced_at: null, sync_window_start: null, sync_window_end: null, sync_page: null }).eq("id", body.shop);
      }
      // Shop lâu chưa đồng bộ nhất chạy trước, để shop lớn không chiếm hết thời gian của shop khác.
      const { data: shops, error } = await q.order("last_synced_at", { ascending: true, nullsFirst: true });
      if (error) throw error;
      const days = Math.min(400, Math.max(1, Number(body.backfill_days) || DEFAULT_BACKFILL_DAYS));
      const results = [];
      for (const s of shops as Shop[]) {
        if (Date.now() > deadline) { results.push({ shop: s.name, status: "skipped", error: "Hết thời gian, lần sau làm tiếp" }); continue; }
        results.push(await syncShop(sb, s, trigger, deadline, days));
      }
      return json({ ok: true, results });
    }

    if (body.action === "refresh") {
      if (!role) return json({ error: "Tài khoản chưa được cấp quyền" }, 403);
      const fresh = new Date(Date.now() - REFRESH_MIN_GAP_MS).toISOString();
      // Chỉ shop đã kéo xong lần đầu; shop đang kéo dở lịch sử để lịch 15 phút làm tiếp.
      const { data: shops, error } = await sb.from("pos_shops").select("*")
        .eq("active", true).not("api_key_secret_id", "is", null)
        .is("sync_window_start", null).not("last_synced_at", "is", null).lt("last_synced_at", fresh);
      if (error) throw error;
      const until = Date.now() + REFRESH_BUDGET_MS;
      const results = await Promise.all((shops as Shop[]).map((s) => syncShop(sb, s, "mở trang: " + trigger, until, DEFAULT_BACKFILL_DAYS)));
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
