import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#operationsWorkspace");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const classSelect = document.querySelector("#operationsClassSelect");
  const orderForm = document.querySelector("#createOrderForm");
  const shipmentForm = document.querySelector("#createShipmentForm");
  const ordersList = document.querySelector("#ordersList");
  const shipmentsList = document.querySelector("#shipmentsList");
  const orderSelect = document.querySelector("#shipmentOrder");
  const note = document.querySelector("#operationsAccessNote");
  const message = document.querySelector("#operationsMessage");
  let user = null;
  let platformRole = "student";
  let operationalRole = "customer";
  let activeClassId = null;

  const el = (tag, cls, value) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (value !== undefined) n.textContent = value;
    return n;
  };
  const option = (label, value) => {
    const n = el("option", "", label);
    n.value = value;
    return n;
  };
  const say = (value, success = false) => {
    message.textContent = value;
    message.classList.toggle("success", success);
  };
  const isTeacher = () => platformRole === "teacher";
  const canOrder = () => isTeacher() || ["customer", "retailer"].includes(operationalRole);
  const canShip = () => isTeacher() || operationalRole === "transport";

  function statusSelect(current, statuses, onChange) {
    const select = el("select", "record-status");
    for (const [value, label] of statuses) {
      const opt = option(label, value);
      opt.selected = value === current;
      select.append(opt);
    }
    select.addEventListener("change", async () => {
      select.disabled = true;
      try { await onChange(select.value); }
      catch (error) { say(error.message); select.value = current; }
      finally { select.disabled = false; }
    });
    return select;
  }

  async function loadOrders() {
    const { data, error } = await db.from("orders")
      .select("id,order_number,product_name,quantity,status,due_at,created_at")
      .eq("classroom_id", activeClassId)
      .order("created_at", { ascending: false }).limit(50);
    if (error) throw error;
    ordersList.replaceChildren();
    orderSelect.replaceChildren(option("No linked order", ""));
    if (!data.length) ordersList.append(el("p", "empty-state", "No orders yet. Create the first customer order."));
    for (const order of data) {
      orderSelect.append(option(order.order_number + " · " + order.product_name, order.id));
      const card = el("article", "operation-record");
      const head = el("div", "operation-record-head");
      const title = el("div", "operation-record-title");
      title.append(el("b", "", order.order_number), el("small", "", order.product_name + " · " + Number(order.quantity).toLocaleString() + " units"));
      head.append(title, el("span", "record-pill " + order.status, order.status.replaceAll("_", " ").toUpperCase()));
      card.append(head);
      const meta = el("div", "operation-record-meta");
      meta.append(el("span", "", order.due_at ? "Due " + new Date(order.due_at).toLocaleString() : "No due date"));
      meta.append(el("span", "", "Created " + new Date(order.created_at).toLocaleDateString()));
      card.append(meta);
      if (isTeacher()) {
        card.append(statusSelect(order.status, [
          ["created","Created"],["approved","Approved"],["in_production","In production"],
          ["ready","Ready"],["in_transit","In transit"],["delivered","Delivered"],
          ["delayed","Delayed"],["cancelled","Cancelled"]
        ], async next => {
          const { error: updateError } = await db.rpc("set_supply_order_status", { p_order_id: order.id, p_status: next });
          if (updateError) throw updateError;
          say("Order status updated.", true);
          await loadOrders();
          await loadShipments();
        }));
      }
      ordersList.append(card);
    }
  }

  async function loadShipments() {
    const { data, error } = await db.from("shipments")
      .select("id,order_id,origin,destination,carrier,status,eta,created_at,orders(order_number)")
      .eq("classroom_id", activeClassId)
      .order("created_at", { ascending: false }).limit(50);
    if (error) throw error;
    shipmentsList.replaceChildren();
    if (!data.length) shipmentsList.append(el("p", "empty-state", "No shipments planned yet."));
    for (const shipment of data) {
      const card = el("article", "operation-record");
      const head = el("div", "operation-record-head");
      const title = el("div", "operation-record-title");
      title.append(el("b", "", shipment.orders?.order_number || "Unlinked shipment"),
        el("small", "", shipment.origin + " → " + shipment.destination));
      head.append(title, el("span", "record-pill " + shipment.status, shipment.status.replaceAll("_", " ").toUpperCase()));
      card.append(head);
      const meta = el("div", "operation-record-meta");
      meta.append(el("span", "", "Carrier · " + shipment.carrier));
      meta.append(el("span", "", shipment.eta ? "ETA " + new Date(shipment.eta).toLocaleString() : "ETA not set"));
      card.append(meta);
      if (canShip()) {
        card.append(statusSelect(shipment.status, [
          ["planned","Planned"],["dispatched","Dispatched"],["in_transit","In transit"],
          ["delayed","Delayed"],["delivered","Delivered"]
        ], async next => {
          const { error: updateError } = await db.rpc("set_supply_shipment_status", { p_shipment_id: shipment.id, p_status: next });
          if (updateError) throw updateError;
          say("Shipment status updated.", true);
          await loadShipments();
        }));
      }
      shipmentsList.append(card);
    }
  }

  async function loadRecords() {
    ordersList.replaceChildren(el("p", "empty-state", "Loading orders…"));
    shipmentsList.replaceChildren(el("p", "empty-state", "Loading shipments…"));
    await loadOrders();
    await loadShipments();
  }

  async function loadClassrooms() {
    let classes = [];
    if (isTeacher()) {
      const { data, error } = await db.from("classrooms").select("id,name")
        .eq("teacher_id", user.id).order("created_at", { ascending: false });
      if (error) throw error;
      classes = data || [];
    } else {
      const { data, error } = await db.from("classroom_members")
        .select("operational_role,classrooms(id,name)")
        .eq("student_id", user.id);
      if (error) throw error;
      const memberships = data || [];
      const allowed = memberships.filter(row => ["customer","retailer","transport"].includes(row.operational_role));
      classes = allowed.map(row => row.classrooms).filter(Boolean);
      operationalRole = allowed[0]?.operational_role || "customer";
      // Keep each class's role for the selected workspace.
      classSelect.dataset.memberships = JSON.stringify(allowed.map(row => ({
        id: row.classrooms?.id, role: row.operational_role
      })));
    }
    classSelect.replaceChildren();
    if (!classes.length) {
      activeClassId = null;
      orderForm.hidden = true;
      shipmentForm.hidden = true;
      ordersList.replaceChildren(el("p", "empty-state", "Join a classroom first, or ask your teacher to assign Customer, Retailer, or Transport role."));
      shipmentsList.replaceChildren();
      return;
    }
    for (const c of classes) classSelect.append(option(c.name, c.id));
    activeClassId = classes[0].id;
    classSelect.value = activeClassId;
    applyPermissions();
    await loadRecords();
  }

  function applyPermissions() {
    if (!isTeacher()) {
      const memberships = JSON.parse(classSelect.dataset.memberships || "[]");
      operationalRole = memberships.find(m => m.id === activeClassId)?.role || "customer";
    }
    orderForm.hidden = !canOrder();
    shipmentForm.hidden = !canShip();
    note.textContent = isTeacher()
      ? "Teacher view · create records, inspect all activity, and control order and shipment status."
      : "Role-based workspace · " + operationalRole + " · actions are validated by the database.";
  }

  async function initialize(session) {
    if (!session?.user) { root.hidden = true; return; }
    user = session.user;
    try {
      const { data: profile, error } = await db.from("profiles").select("platform_role").eq("id", user.id).single();
      if (error) throw error;
      platformRole = profile.platform_role || "student";
      if (!isTeacher()) {
        const { data: memberships, error: membershipError } = await db.from("classroom_members")
          .select("operational_role").eq("student_id", user.id);
        if (membershipError) throw membershipError;
        if (!(memberships || []).some(row => ["customer","retailer","transport"].includes(row.operational_role))) {
          root.hidden = true;
          return;
        }
      }
      root.hidden = false;
      await loadClassrooms();
    } catch (error) {
      root.hidden = false;
      say("Operations could not load: " + error.message);
    }
  }

  classSelect.addEventListener("change", async () => {
    activeClassId = classSelect.value;
    applyPermissions();
    try { await loadRecords(); say(""); } catch (error) { say(error.message); }
  });

  orderForm.addEventListener("submit", async event => {
    event.preventDefault();
    if (!activeClassId || !canOrder()) return;
    const button = orderForm.querySelector("button[type=submit]");
    button.disabled = true;
    try {
      const dueValue = document.querySelector("#orderDueAt").value;
      const { error } = await db.rpc("create_supply_order", {
        p_classroom_id: activeClassId,
        p_order_number: document.querySelector("#orderNumber").value.trim(),
        p_product_name: document.querySelector("#orderProduct").value.trim(),
        p_quantity: Number(document.querySelector("#orderQuantity").value),
        p_due_at: dueValue ? new Date(dueValue).toISOString() : null
      });
      if (error) throw error;
      orderForm.reset();
      document.querySelector("#orderQuantity").value = "10";
      say("Customer order created and saved.", true);
      await loadRecords();
    } catch (error) { say(error.message); }
    finally { button.disabled = false; }
  });

  shipmentForm.addEventListener("submit", async event => {
    event.preventDefault();
    if (!activeClassId || !canShip()) return;
    const button = shipmentForm.querySelector("button[type=submit]");
    button.disabled = true;
    try {
      const etaValue = document.querySelector("#shipmentEta").value;
      const { error } = await db.rpc("create_supply_shipment", {
        p_classroom_id: activeClassId,
        p_order_id: orderSelect.value || null,
        p_origin: document.querySelector("#shipmentOrigin").value.trim(),
        p_destination: document.querySelector("#shipmentDestination").value.trim(),
        p_carrier: document.querySelector("#shipmentCarrier").value.trim(),
        p_eta: etaValue ? new Date(etaValue).toISOString() : null
      });
      if (error) throw error;
      shipmentForm.reset();
      document.querySelector("#shipmentCarrier").value = "Demo carrier";
      say("Shipment planned and saved.", true);
      await loadRecords();
    } catch (error) { say(error.message); }
    finally { button.disabled = false; }
  });

  db.auth.getSession().then(({ data }) => initialize(data.session));
  db.auth.onAuthStateChange((_event, session) => {
    if (session) setTimeout(() => initialize(session), 0);
    else { root.hidden = true; user = null; activeClassId = null; }
  });
}
