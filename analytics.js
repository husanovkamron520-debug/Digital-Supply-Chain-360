import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#teacherAnalytics");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const picker = document.querySelector("#analyticsClassSelect");
  const grid = document.querySelector("#analyticsMetrics");
  const note = document.querySelector("#analyticsNote");
  let activeClassId = null;

  const metric = (label, value, detail) => {
    const card = document.createElement("article");
    card.className = "analytics-metric";
    const title = document.createElement("span");
    title.textContent = label;
    const number = document.createElement("strong");
    number.textContent = value;
    const caption = document.createElement("small");
    caption.textContent = detail;
    card.append(title, number, caption);
    return card;
  };

  async function refresh() {
    if (!activeClassId) return;
    note.textContent = "Refreshing classroom data…";
    grid.replaceChildren();
    const [orders, shipments, inventory, decisions, members] = await Promise.all([
      db.from("orders").select("id,status", { count: "exact" }).eq("classroom_id", activeClassId).is("scenario_id", null),
      db.from("shipments").select("id,status", { count: "exact" }).eq("classroom_id", activeClassId).is("scenario_id", null),
      db.from("inventory").select("quantity,reorder_level").eq("classroom_id", activeClassId).is("scenario_id", null),
      db.from("scenario_decisions").select("score,student_id").eq("classroom_id", activeClassId),
      db.from("classroom_members").select("id", { count: "exact", head: true }).eq("classroom_id", activeClassId)
    ]);
    for (const result of [orders, shipments, inventory, decisions, members]) {
      if (result.error) throw result.error;
    }
    const orderRows = orders.data || [];
    const shipmentRows = shipments.data || [];
    const stockRows = inventory.data || [];
    const scoreRows = decisions.data || [];
    const studentCount = members.count ?? 0;
    const participating = new Set(scoreRows.map(row => row.student_id)).size;
    const participationRate = studentCount ? Math.round(participating / studentCount * 100) : 0;
    const units = stockRows.reduce((sum, row) => sum + Number(row.quantity || 0), 0);
    const lowStock = stockRows.filter(row => Number(row.quantity) <= Number(row.reorder_level)).length;
    const inTransit = shipmentRows.filter(row => ["dispatched", "in_transit"].includes(row.status)).length;
    const average = scoreRows.length
      ? Math.round(scoreRows.reduce((sum, row) => sum + Number(row.score || 0), 0) / scoreRows.length)
      : null;
    grid.append(
      metric("Customer orders", String(orders.count ?? orderRows.length), orderRows.filter(row => !["delivered", "cancelled"].includes(row.status)).length + " open / active"),
      metric("Shipments in transit", String(inTransit), (shipments.count ?? shipmentRows.length) + " total shipments"),
      metric("Inventory units", units.toLocaleString(), stockRows.length + " SKUs · " + lowStock + " at/below reorder level"),
      metric("Scenario average", average === null ? "—" : average + "/100", scoreRows.length + " student decisions"),
      metric("Student participation", participating + " / " + studentCount, participationRate + "% of enrolled students submitted at least one decision")
    );
    note.textContent = "Live classroom records · refreshed " + new Date().toLocaleTimeString();
  }

  async function initialize(session) {
    if (!session?.user) { root.hidden = true; return; }
    try {
      const { data: profile, error } = await db.from("profiles").select("platform_role").eq("id", session.user.id).single();
      if (error) throw error;
      if (profile.platform_role !== "teacher") { root.hidden = true; return; }
      const analyticsNav = document.querySelector("#analyticsNavLink");
      if (analyticsNav) analyticsNav.hidden = false;
      const { data: classes, error: classError } = await db.from("classrooms").select("id,name")
        .eq("teacher_id", session.user.id).order("created_at", { ascending: false });
      if (classError) throw classError;
      root.hidden = false;
      picker.replaceChildren();
      for (const classroom of classes || []) {
        const option = document.createElement("option");
        option.value = classroom.id;
        option.textContent = classroom.name;
        picker.append(option);
      }
      if (!classes?.length) {
        note.textContent = "Create a classroom to see its operational performance.";
        grid.replaceChildren();
        return;
      }
      activeClassId = classes[0].id;
      picker.value = activeClassId;
      await refresh();
    } catch (error) {
      root.hidden = false;
      note.textContent = "Analytics unavailable: " + error.message;
    }
  }

  picker.addEventListener("change", async () => {
    activeClassId = picker.value;
    try { await refresh(); } catch (error) { note.textContent = "Analytics unavailable: " + error.message; }
  });
  db.auth.getSession().then(({ data }) => initialize(data.session));
  db.auth.onAuthStateChange((_event, session) => {
    if (session) setTimeout(() => initialize(session), 0);
    else root.hidden = true;
  });
}
