import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#inventoryWorkspace");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const classSelect = document.querySelector("#inventoryClassSelect");
  const form = document.querySelector("#addInventoryForm");
  const list = document.querySelector("#inventoryList");
  const history = document.querySelector("#inventoryHistory");
  const message = document.querySelector("#inventoryMessage");
  const addPanel = document.querySelector("#inventoryAddPanel");
  const accessNote = document.querySelector("#inventoryAccessNote");
  let user = null;
  let role = "student";
  let activeClassId = null;

  function say(text, success = false) {
    message.textContent = text;
    message.classList.toggle("success", success);
  }
  function node(tag, className, text) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function option(label, value) {
    const el = node("option", "", label);
    el.value = value;
    return el;
  }
  function canManage() {
    return role === "teacher" || role === "warehouse";
  }

  async function loadInventory() {
    if (!activeClassId) return;
    list.replaceChildren(node("p", "empty-state", "Loading inventory…"));
    const { data, error } = await db.from("inventory")
      .select("id,sku,item_name,quantity,reorder_level,updated_at")
      .eq("classroom_id", activeClassId)
      .is("scenario_id", null)
      .order("sku");
    if (error) throw error;
    list.replaceChildren();
    if (!data.length) {
      list.append(node("p", "empty-state", "No stock items yet. Add the first product above."));
    }
    for (const item of data) {
      const card = node("article", "stock-card");
      const details = node("div", "stock-details");
      details.append(node("b", "", item.item_name), node("small", "", "SKU · " + item.sku));
      const amount = node("div", "stock-amount");
      amount.append(node("strong", "", String(item.quantity)), node("small", "", "units"));
      const status = node("span", "stock-status " + (item.quantity <= item.reorder_level ? "low" : "healthy"),
        item.quantity <= item.reorder_level ? "LOW STOCK" : "HEALTHY");
      const meta = node("small", "stock-reorder", "Reorder level: " + item.reorder_level);
      const head = node("div", "stock-card-head");
      head.append(details, amount, status);
      card.append(head, meta);
      if (canManage()) {
        const actions = node("div", "stock-actions");
        const qty = document.createElement("input");
        qty.type = "number"; qty.min = "1"; qty.step = "1"; qty.value = "1";
        qty.setAttribute("aria-label", "Quantity to receive or issue");
        const receive = node("button", "stock-receive", "＋ Receive");
        const issue = node("button", "stock-issue", "− Issue");
        receive.type = issue.type = "button";
        receive.addEventListener("click", () => adjust(item, Math.max(1, Number(qty.value) || 1)));
        issue.addEventListener("click", () => adjust(item, -Math.max(1, Number(qty.value) || 1)));
        actions.append(qty, receive, issue);
        card.append(actions);
      }
      list.append(card);
    }
    await loadHistory();
  }

  async function loadHistory() {
    const { data, error } = await db.from("activity_logs")
      .select("event_type,description,created_at")
      .eq("classroom_id", activeClassId)
      .in("event_type", ["inventory_item_created", "inventory_received", "inventory_issued"])
      .order("created_at", { ascending: false })
      .limit(8);
    if (error) throw error;
    history.replaceChildren();
    if (!data.length) {
      history.append(node("p", "empty-state", "No inventory activity yet."));
      return;
    }
    for (const event of data) {
      const row = node("div", "inventory-history-row");
      const when = new Date(event.created_at).toLocaleString();
      row.append(node("span", "", event.description), node("small", "", when));
      history.append(row);
    }
  }

  async function adjust(item, delta) {
    const buttons = list.querySelectorAll("button");
    buttons.forEach(button => button.disabled = true);
    say("");
    try {
      const { error } = await db.rpc("adjust_inventory_quantity", {
        p_inventory_id: item.id,
        p_delta: delta,
        p_reason: delta > 0 ? "Warehouse receipt" : "Warehouse issue"
      });
      if (error) throw error;
      say("Stock updated successfully.", true);
      await loadInventory();
    } catch (error) {
      say(error.message);
      buttons.forEach(button => button.disabled = false);
    }
  }

  async function selectClassrooms(sessionUser, platformRole) {
    let classes = [];
    if (platformRole === "teacher") {
      const { data, error } = await db.from("classrooms")
        .select("id,name").eq("teacher_id", sessionUser.id).order("created_at", { ascending: false });
      if (error) throw error;
      classes = data || [];
    } else {
      const { data, error } = await db.from("classroom_members")
        .select("operational_role,classrooms(id,name)")
        .eq("student_id", sessionUser.id).eq("operational_role", "warehouse");
      if (error) throw error;
      classes = (data || []).map(row => row.classrooms).filter(Boolean);
    }
    classSelect.replaceChildren();
    if (!classes.length) {
      activeClassId = null;
      list.replaceChildren(node("p", "empty-state",
        platformRole === "teacher" ? "Create a classroom first." : "This workspace is available to students assigned the Warehouse Manager role."));
      form.hidden = true;
      addPanel.hidden = true;
      history.replaceChildren();
      return;
    }
    for (const classroom of classes) classSelect.append(option(classroom.name, classroom.id));
    activeClassId = classes[0].id;
    classSelect.value = activeClassId;
    form.hidden = !canManage();
    addPanel.hidden = !canManage();
    await loadInventory();
  }

  async function initialize(session) {
    if (!session?.user) { root.hidden = true; return; }
    user = session.user;
    try {
      const { data: profile, error } = await db.from("profiles")
        .select("platform_role").eq("id", user.id).single();
      if (error) throw error;
      role = profile.platform_role || "student";
      if (role === "teacher") {
        root.hidden = false;
        accessNote.textContent = "Teacher view · select one of your classrooms to inspect its stock.";
        await selectClassrooms(user, role);
      } else {
        const { data: memberships, error: membershipError } = await db.from("classroom_members")
          .select("operational_role").eq("student_id", user.id);
        if (membershipError) throw membershipError;
        const warehouse = (memberships || []).some(row => row.operational_role === "warehouse");
        if (!warehouse) { root.hidden = true; return; }
        root.hidden = false;
        accessNote.textContent = "Warehouse Manager workspace · stock changes are saved and recorded.";
        await selectClassrooms(user, "warehouse");
      }
    } catch (error) {
      root.hidden = false;
      list.replaceChildren(node("p", "empty-state", error.message));
      say("Inventory could not be loaded. Check that the inventory SQL migration has been applied.");
    }
  }

  classSelect.addEventListener("change", async () => {
    activeClassId = classSelect.value;
    try { await loadInventory(); say(""); }
    catch (error) { say(error.message); }
  });

  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (!activeClassId || !canManage()) return;
    const button = form.querySelector("button[type=submit]");
    button.disabled = true;
    say("");
    try {
      const sku = document.querySelector("#inventorySku").value.trim().toUpperCase();
      const name = document.querySelector("#inventoryItemName").value.trim();
      const quantity = Number(document.querySelector("#inventoryOpeningQty").value);
      const reorder = Number(document.querySelector("#inventoryReorderLevel").value);
      const { error } = await db.rpc("create_inventory_item", {
        p_classroom_id: activeClassId,
        p_sku: sku,
        p_item_name: name,
        p_quantity: quantity,
        p_reorder_level: reorder
      });
      if (error) throw error;
      form.reset();
      say("Product added to inventory.", true);
      await loadInventory();
    } catch (error) {
      say(error.message);
    } finally {
      button.disabled = false;
    }
  });

  db.auth.getSession().then(({ data }) => initialize(data.session));
  db.auth.onAuthStateChange((_event, session) => {
    if (session) setTimeout(() => initialize(session), 0);
    else { root.hidden = true; user = null; activeClassId = null; }
  });
}
