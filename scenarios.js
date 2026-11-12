import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#scenarioWorkspace");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const classSelect = document.querySelector("#scenarioClassSelect");
  const launchForm = document.querySelector("#scenarioLaunchForm");
  const scenarioList = document.querySelector("#scenarioList");
  const note = document.querySelector("#scenarioAccessNote");
  const message = document.querySelector("#scenarioMessage");
  let user = null;
  let isTeacher = false;
  let activeClassId = null;

  const el = (tag, cls, value) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (value !== undefined) node.textContent = value;
    return node;
  };
  const option = (label, value) => {
    const node = el("option", "", label);
    node.value = value;
    return node;
  };
  const say = (value, success = false) => {
    message.textContent = value;
    message.classList.toggle("success", success);
  };
  const dateLabel = value => value ? new Date(value).toLocaleString() : "Not started";

  async function renderScenario(scenario) {
    const card = el("article", "scenario-card " + scenario.status);
    const header = el("div", "scenario-card-header");
    const titleWrap = el("div", "scenario-title-wrap");
    titleWrap.append(el("h3", "", scenario.title));
    titleWrap.append(el("p", "scenario-description", scenario.configuration?.description || "Operational disruption scenario"));
    header.append(titleWrap, el("span", "scenario-status " + scenario.status, scenario.status.toUpperCase()));
    card.append(header);
    card.append(el("p", "scenario-impact", "Potential impact: " + (scenario.configuration?.impact || "Operational performance may be affected.")));
    card.append(el("small", "scenario-date", "Started " + dateLabel(scenario.started_at || scenario.created_at)));

    const [simOrders, simShipments, simStock] = await Promise.all([
      db.from("orders").select("order_number,product_name,quantity,status").eq("scenario_id", scenario.id),
      db.from("shipments").select("origin,destination,status,eta").eq("scenario_id", scenario.id),
      db.from("inventory").select("sku,item_name,quantity,reorder_level").eq("scenario_id", scenario.id)
    ]);
    for (const result of [simOrders, simShipments, simStock]) {
      if (result.error) throw result.error;
    }
    const simulation = el("div", "scenario-operations-snapshot");
    simulation.append(el("b", "", "Simulated operations"));
    for (const order of simOrders.data || []) {
      simulation.append(el("p", "", order.order_number + " · " + order.status.replaceAll("_", " ") + " · " + Number(order.quantity).toLocaleString() + " units"));
    }
    for (const stock of simStock.data || []) {
      simulation.append(el("p", "", stock.item_name + " · " + Number(stock.quantity).toLocaleString() + " units · reorder at " + stock.reorder_level));
    }
    if (simShipments.data?.length) {
      const moving = simShipments.data.filter(item => item.status === "in_transit").length;
      simulation.append(el("p", "", simShipments.data.length + " shipments · " + moving + " in transit"));
    }
    card.append(simulation);

    const { data: decisions, error } = await db.from("scenario_decisions")
      .select("id,student_id,selected_action,rationale,score,feedback,submitted_at")
      .eq("scenario_id", scenario.id)
      .order("score", { ascending: false });
    if (error) throw error;

    if (isTeacher) {
      const summary = el("div", "scenario-results-summary");
      const average = decisions.length
        ? Math.round(decisions.reduce((sum, row) => sum + row.score, 0) / decisions.length)
        : 0;
      summary.append(
        el("span", "", decisions.length + " student response" + (decisions.length === 1 ? "" : "s")),
        el("b", "", decisions.length ? "Average score: " + average + "/100" : "No responses yet")
      );
      card.append(summary);
      if (decisions.length) {
        const results = el("div", "scenario-results");
        for (const decision of decisions) {
          const row = el("div", "scenario-result-row");
          row.append(el("span", "", "Student " + decision.student_id.slice(0, 8)));
          row.append(el("b", "", decision.score + "/100"));
          row.append(el("small", "", decision.selected_action.replaceAll("_", " ") + (decision.rationale ? " · " + decision.rationale : "")));
          results.append(row);
        }
        card.append(results);
      }
      if (scenario.status === "active") {
        const finish = el("button", "scenario-secondary-button", "Complete scenario");
        finish.type = "button";
        finish.addEventListener("click", async () => {
          finish.disabled = true;
          try {
            const { error: finishError } = await db.rpc("complete_supply_scenario", { p_scenario_id: scenario.id });
            if (finishError) throw finishError;
            say("Scenario completed. Student results are saved.", true);
            await loadScenarios();
          } catch (error) { say(error.message); finish.disabled = false; }
        });
        card.append(finish);
      }
    } else {
      const myDecision = decisions.find(row => row.student_id === user.id);
      if (myDecision) {
        const result = el("div", "scenario-own-result");
        result.append(el("b", "", "Your score: " + myDecision.score + "/100"));
        result.append(el("p", "", myDecision.feedback));
        result.append(el("small", "", "Submitted " + dateLabel(myDecision.submitted_at)));
        card.append(result);
      } else if (scenario.status === "active") {
        const actions = Array.isArray(scenario.configuration?.actions) ? scenario.configuration.actions : [];
        const form = el("form", "scenario-decision-form");
        form.append(el("label", "", "Choose your operational response"));
        const select = el("select", "scenario-action-select");
        select.required = true;
        select.append(option("Select a decision…", ""));
        for (const action of actions) select.append(option(action.label, action.key));
        form.append(select);
        const rationale = el("textarea", "scenario-rationale");
        rationale.maxLength = 1000;
        rationale.rows = 2;
        rationale.placeholder = "Explain why you chose this action (optional)";
        form.append(rationale);
        const submit = el("button", "primary-button", "Submit decision");
        submit.type = "submit";
        form.append(submit);
        form.addEventListener("submit", async event => {
          event.preventDefault();
          if (!select.value) return;
          submit.disabled = true;
          try {
            const { data, error: submitError } = await db.rpc("submit_scenario_decision", {
              p_scenario_id: scenario.id,
              p_action_key: select.value,
              p_rationale: rationale.value.trim()
            });
            if (submitError) throw submitError;
            const effect = data.simulation ? " · Simulation: " + data.simulation.order_status.replaceAll("_", " ") + (data.simulation.stock_units ? " · " + data.simulation.stock_units + " stock units" : "") + (data.simulation.shipment_count ? " · " + data.simulation.shipment_count + " shipments" : "") : "";\n            say("Decision saved · Score " + data.score + "/100. " + data.feedback + effect, true);
            await loadScenarios();
          } catch (error) { say(error.message); submit.disabled = false; }
        });
        card.append(form);
      } else {
        card.append(el("p", "scenario-closed-note", "This scenario is complete. Your teacher can review the class results."));
      }
    }
    return card;
  }

  async function loadScenarios() {
    scenarioList.replaceChildren(el("p", "empty-state", "Loading scenarios…"));
    const { data, error } = await db.from("scenarios")
      .select("id,title,status,configuration,started_at,created_at,completed_at")
      .eq("classroom_id", activeClassId)
      .order("created_at", { ascending: false }).limit(12);
    if (error) throw error;
    scenarioList.replaceChildren();
    if (!data.length) {
      scenarioList.append(el("p", "empty-state", "No scenarios yet. Your teacher can launch the first disruption exercise."));
      return;
    }
    for (const scenario of data) scenarioList.append(await renderScenario(scenario));
  }

  async function loadClasses() {
    let classes = [];
    if (isTeacher) {
      const { data, error } = await db.from("classrooms").select("id,name")
        .eq("teacher_id", user.id).order("created_at", { ascending: false });
      if (error) throw error;
      classes = data || [];
    } else {
      const { data, error } = await db.from("classroom_members")
        .select("classrooms(id,name)").eq("student_id", user.id);
      if (error) throw error;
      classes = (data || []).map(row => row.classrooms).filter(Boolean);
    }
    classSelect.replaceChildren();
    for (const classroom of classes) classSelect.append(option(classroom.name, classroom.id));
    if (!classes.length) {
      activeClassId = null;
      launchForm.hidden = true;
      scenarioList.replaceChildren(el("p", "empty-state", "Join a classroom to access scenario simulations."));
      return;
    }
    activeClassId = classes[0].id;
    classSelect.value = activeClassId;
    launchForm.hidden = !isTeacher;
    note.textContent = isTeacher
      ? "Teacher mode · launch disruption exercises and review class decisions and scores."
      : "Student mode · analyse the disruption, choose an action, and explain your reasoning.";
    await loadScenarios();
  }

  async function initialize(session) {
    if (!session?.user) { root.hidden = true; return; }
    user = session.user;
    try {
      const { data: profile, error } = await db.from("profiles").select("platform_role").eq("id", user.id).single();
      if (error) throw error;
      isTeacher = profile.platform_role === "teacher";
      root.hidden = false;
      await loadClasses();
    } catch (error) {
      root.hidden = false;
      say("Scenario engine could not load: " + error.message);
    }
  }

  classSelect.addEventListener("change", async () => {
    activeClassId = classSelect.value;
    try { await loadScenarios(); say(""); } catch (error) { say(error.message); }
  });

  launchForm.addEventListener("submit", async event => {
    event.preventDefault();
    if (!activeClassId || !isTeacher) return;
    const button = launchForm.querySelector("button");
    button.disabled = true;
    try {
      const { error } = await db.rpc("launch_supply_scenario", {
        p_classroom_id: activeClassId,
        p_scenario_type: document.querySelector("#scenarioType").value
      });
      if (error) throw error;
      say("Scenario launched. Students can now submit their decisions.", true);
      await loadScenarios();
    } catch (error) { say(error.message); }
    finally { button.disabled = false; }
  });

  db.auth.getSession().then(({ data }) => initialize(data.session));
  db.auth.onAuthStateChange((_event, session) => {
    if (session) setTimeout(() => initialize(session), 0);
    else { root.hidden = true; user = null; activeClassId = null; }
  });
}
