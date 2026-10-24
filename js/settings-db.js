// Cầu nối giữa màn Cài đặt (viết theo kiểu collection/doc) và 2 bảng Supabase: pos_shops, ffm_units.
// Đổi tên cột camelCase ↔ snake_case; nghe realtime để nhiều người sửa cùng lúc đều thấy.
(function () {
  const MAP = {
    shops: {
      table: "pos_shops",
      cols: "id, channel, name, pos_shop_id, team, staff, active",
      toRow: (d) => ({ channel: d.channel, name: d.name, pos_shop_id: d.posShopId || "", team: d.team || "", staff: d.staff || "", active: d.active !== false }),
      fromRow: (r) => ({ channel: r.channel, name: r.name, posShopId: r.pos_shop_id, team: r.team, staff: r.staff, active: r.active }),
    },
    ffm: {
      table: "ffm_units",
      cols: "id, name, warehouse, fee_pct, ship_php, share, note",
      toRow: (d) => ({ name: d.name, warehouse: d.warehouse || "", fee_pct: +d.feePct || 0, ship_php: +d.shipPhp || 0, share: +d.share || 0, note: d.note || "" }),
      fromRow: (r) => ({ name: r.name, warehouse: r.warehouse, feePct: +r.fee_pct, shipPhp: +r.ship_php, share: +r.share, note: r.note }),
    },
  };

  window.SettingsDB = function (sb) {
    const listeners = {}, ids = {};
    async function load(name) {
      const m = MAP[name];
      const { data, error } = await sb.from(m.table).select(m.cols);
      const ls = listeners[name] || [];
      if (error) { ls.forEach((l) => l.err && l.err(error)); return; }
      ids[name] = new Set(data.map((r) => r.id));
      const snap = { docs: data.map((r) => ({ id: r.id, data: () => m.fromRow(r) })) };
      ls.forEach((l) => l.cb(snap));
    }
    return {
      collection(name) {
        const m = MAP[name];
        if (!m) throw new Error("Không có bảng " + name);
        return {
          onSnapshot(cb, err) {
            (listeners[name] = listeners[name] || []).push({ cb, err });
            load(name);
            sb.channel("settings-" + m.table)
              .on("postgres_changes", { event: "*", schema: "public", table: m.table }, () => load(name))
              .subscribe();
          },
          doc(id) {
            return {
              async set(data) {
                const row = m.toRow(data);
                // Không dùng upsert: người sửa không có quyền ghi cột id.
                const known = ids[name] && ids[name].has(id);
                const { data: done, error } = known
                  ? await sb.from(m.table).update(row).eq("id", id).select("id")
                  : await sb.from(m.table).insert(Object.assign({ id }, row)).select("id");
                if (error) throw error;
                if (!done || !done.length) throw new Error("tài khoản của cậu không có quyền sửa mục này");
                await load(name);
              },
              async delete() {
                const { data: done, error } = await sb.from(m.table).delete().eq("id", id).select("id");
                if (error) throw error;
                if (!done || !done.length) throw new Error("tài khoản của cậu không có quyền xoá mục này");
                await load(name);
              },
            };
          },
        };
      },
    };
  };
})();
