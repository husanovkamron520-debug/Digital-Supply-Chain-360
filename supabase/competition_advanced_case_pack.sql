-- Advanced, quantitative, role-specific case pack for the competition engine.
-- All case figures are synthetic educational data, not company internal data.
create or replace function public.create_competition_standard_task_pack(p_competition_id uuid)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
 v_classroom_id uuid;
 v_status text;
 v_team record;
 v_count integer := 0;
 v_context text;
 v_proc text;
 v_supplier text;
 v_mfg text;
 v_wh text;
 v_transport text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create standard team tasks'; end if;
 if v_status not in ('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then
  raise exception 'Tasks already exist. Add custom tasks instead of duplicating the advanced case pack';
 end if;
 for v_team in
  select t.id,t.name,ct.name as company_name,ct.slug
  from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id
  where t.competition_id=p_competition_id
 loop
  if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='procurement')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='supplier')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='manufacturer')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='warehouse')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='transport') then
   raise exception 'Each team must have Procurement, Supplier, Manufacturer, Warehouse and Transport roles before generating the advanced case pack';
  end if;
  v_context := case v_team.slug
   when 'lean-automotive' then 'CONTEXT: lean automotive assembly; protect line continuity, traceability and just-in-time flow.'
   when 'omnichannel-retail' then 'CONTEXT: omnichannel retail fulfilment; balance store availability, fulfilment-node placement and last-mile promises.'
   when 'flatpack-global' then 'CONTEXT: global flat-pack furniture; account for cube utilisation, packaging damage and long international lead times.'
   when 'beverage-fast-moving' then 'CONTEXT: fast-moving beverages; account for FIFO, shelf-life, packaging availability and seasonal demand.'
   else 'CONTEXT: multi-echelon supply chain; balance service, cost, capacity and operational risk.'
  end;
  v_proc := v_context || E'\n\nCASE DATA (synthetic): 14-day demand forecast = 2,400 units; target customer service = 98%; annual holding rate = 22% of unit value; stockout/expedite exposure is estimated at $22 per unmet unit; each defective unit creates $7 rework/disposal cost. Compare three qualified offers: A = $4.85/unit, 5-day lead time, 98.5% fill rate, 1.2% defect rate, MOQ 500; B = $4.55/unit, 8-day lead time, 94.0% fill rate, 2.8% defect rate, MOQ 1,000; C = $5.10/unit, 3-day lead time, 99.2% fill rate, 0.6% defect rate, MOQ 750.\n\nREQUIRED ANALYSIS: (1) calculate expected received-good quantity and expected defective units for a 2,400-unit requirement; (2) estimate purchase cost, expected defect units, $7-per-defect rework/disposal cost and $22-per-unmet-unit service exposure for each offer; (3) calculate service/lead-time risk and recommend an order split or single-source strategy; (4) calculate the order quantity needed to deliver 2,400 good units in expectation using Q = 2,400 / (fill rate × (1 − defect rate)), round up to whole units and test each offer's MOQ; (5) state the reorder trigger, contingency supplier and maximum acceptable premium. Do not select by unit price alone.\n\nSUBMISSION: show formulas, assumptions, comparison table, final sourcing decision and one quantified downside scenario.\n\nASSESSMENT / 100: calculations 30; total-cost and quality analysis 25; service-risk trade-off 20; feasible sourcing plan 15; evidence and contingency 10. Case figures are separate from the live operational ledger; do not enter invented receipts or orders.';
  v_supplier := v_context || E'\n\nCASE DATA (synthetic): the incumbent supplied 10,000 units last quarter; 9,100 arrived within the agreed window, 240 units failed incoming quality inspection, and average lead time was 6.2 days against a 5-day contract. A proposed revised contract offers a 3% unit-price discount only if MOQ rises from 1,000 to 2,500 units and no late-delivery penalty is accepted. A second offer costs $0.18 more per unit, promises 99% OTIF, 4-day lead time and a 2% service credit for late deliveries. Forecast demand is 2,400 units per 14 days; available storage headroom is limited.\n\nREQUIRED ANALYSIS: (1) calculate incumbent OTIF = 9,100 / 10,000 and incoming defect rate = 240 / 10,000 shipped units; (2) quantify the cash tied up by the higher MOQ using the current unit price shown in the team workspace; (3) compare the discount against the premium and expected disruption exposure; (4) propose measurable SLA terms for OTIF, defect rate, lead time, notification window, corrective action and service credits; (5) define a supplier scorecard and escalation trigger.\n\nSUBMISSION: negotiation position, target / walk-away terms, calculations and fallback plan. Explain which concessions you would exchange rather than demanding every improvement for free.\n\nASSESSMENT / 100: KPI calculations 20; commercial analysis 25; SLA design 25; risk and fallback 20; clarity 10. Case figures are synthetic and do not overwrite live supplier records.';
  v_mfg := v_context || E'\n\nCASE DATA (synthetic): firm customer requirement = 2,400 good units over 10 days; opening usable raw material = 2,650 units; safety stock requirement = 500 units; production capacity = 320 gross units/day; first-pass yield = 96%; one planned 1-day maintenance stop; a changeover consumes 1.5 production days; assume one raw-material unit is consumed per gross unit and the 500-unit safety stock cannot be consumed. A rush batch can add up to 250 gross units of capacity at $3.20 per extra gross unit. An emergency supplier can deliver 400 raw-material units on day 3 at a $1.10/unit premium.\n\nREQUIRED ANALYSIS: (1) calculate gross production quantity needed to deliver 2,400 good units at 96% yield; (2) calculate net production days after maintenance and changeover, then test capacity feasibility; (3) calculate raw-material balance after the run and whether safety stock is breached; (4) compare a revised schedule / partial fulfilment with using 100 extra gross units of rush capacity and buying emergency raw material; quantify the incremental premium and ending safety-stock balance; (5) produce a day-by-day sequence with a quality hold point and escalation trigger.\n\nSUBMISSION: capacity and yield calculations, production schedule, material plan, chosen recovery option and downstream impact on Warehouse and Transport.\n\nASSESSMENT / 100: yield/capacity calculations 30; material feasibility 20; schedule quality 20; cost/service trade-off 20; cross-functional coordination 10.';
  v_wh := v_context || E'\n\nCASE DATA (synthetic): physical stock = 3,600 units; already allocated to orders = 1,250; quality quarantine = 40; baseline demand = 350 units/day; revised forecast = 420 units/day for the next 5 days (+20%); supplier lead time = 4 days; safety stock target = 900 units; open purchase order = 2,400 units. Supplier can deliver all 2,400 on day 2, or split it into 600 on day 2 and 1,800 on day 5; split option surcharge = $0.35 per expedited unit. Warehouse occupied capacity at the start of day 2, before inbound receipt = 4,050 units; maximum capacity = 4,500; inbound receipts arrive at the start of the stated day; outbound demand clears exactly 420 units at the end of each day. Temporary overflow storage costs $1.80 per excess unit per day.\n\nREQUIRED ANALYSIS: (1) calculate available-to-promise stock after allocations and quarantine; (2) calculate reorder point under baseline and surge demand using ROP = demand during lead time + safety stock; (3) calculate inventory position including the open PO and explain whether a new order is justified; (4) calculate end-of-day occupied capacity and overflow units for days 2–5 under both full receipt and split receipt; calculate total overflow unit-days across all four days, then compare full-receipt overflow cost with split-receipt overflow cost plus the $0.35-per-unit surcharge on the 600-unit expedited tranche; (5) define receiving, put-away, FIFO/FEFO where relevant, cycle-count and escalation controls; (6) give a 5-day action plan that protects service without hiding stock or inventing transactions.\n\nSUBMISSION: show every formula and unit, a 5-day stock/capacity table, chosen receipt schedule, cost comparison, risk register and message to Procurement / Manufacturer / Transport. Case figures are separate from the live ledger; use only actual displayed POs for real receipt actions.\n\nASSESSMENT / 100: inventory and ROP calculations 25; capacity / receipt calculations 25; cost and service trade-off 20; control design 15; cross-functional plan and evidence 15.';
  v_transport := v_context || E'\n\nCASE DATA (synthetic): three customer orders are ready for dispatch: Order A = 900 units due in 2 days; Order B = 700 units due in 4 days; Order C = 600 units due in 5 days. Available vehicle capacity = 1,000 units per trip. Route options: Economy = $0.42/unit, 4 days transit, 96% on-time probability; Standard = $0.58/unit, 2 days transit, 98% on-time probability; Express = $0.91/unit, 1 day transit, 99.5% on-time probability. A late order incurs a $12/unit service penalty; split loads are allowed; every dispatched trip costs a fixed $180 dispatch fee, including the first trip. Transit time starts at dispatch and due dates are measured from today.\n\nREQUIRED ANALYSIS: (1) build a feasible load plan for all 2,200 units, respecting the 1,000-unit capacity and calculating the minimum number of trips; (2) calculate variable freight plus all fixed dispatch fees for at least two routing plans; (3) for each order and plan calculate expected late units = order quantity × (1 − on-time probability), then expected service penalty at $12 per expected late unit; (4) compare total expected logistics cost = freight + dispatch fees + expected service penalties; (5) recommend which orders need express, standard or economy service; (5) explain consolidation versus service-level trade-offs and define shipment tracking / exception triggers.\n\nSUBMISSION: route and load table, cost calculations, expected-risk comparison and dispatch sequence.\n\nASSESSMENT / 100: capacity/load plan 20; cost calculations 25; due-date and risk analysis 25; service trade-off 20; execution controls 10.';
  insert into public.competition_tasks
   (competition_id,team_id,classroom_id,assigned_role,title,description,priority,due_at,due_round,created_by)
  values
   (p_competition_id,v_team.id,v_classroom_id,'procurement',
    case v_team.slug when 'lean-automotive' then 'Strategic sourcing under JIT service constraints' when 'omnichannel-retail' then 'Replenishment sourcing and network availability' when 'flatpack-global' then 'Global sourcing and landed-cost decision' when 'beverage-fast-moving' then 'Ingredient and packaging sourcing risk' else 'Strategic sourcing and total-cost analysis' end,
    v_proc,'critical',null,1,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'supplier','Supplier SLA negotiation and performance recovery',v_supplier,'high',null,1,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'manufacturer','Yield, capacity and production recovery plan',v_mfg,'critical',null,2,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'warehouse','Inventory policy, capacity and inbound-receipt optimisation',v_wh,'critical',null,2,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'transport','Multi-order routing, load consolidation and OTIF recovery',v_transport,'high',null,3,(select auth.uid()));
  v_count := v_count + 5;
 end loop;
 return v_count;
end;
$function$;
revoke all on function public.create_competition_standard_task_pack(uuid) from public, anon;
grant execute on function public.create_competition_standard_task_pack(uuid) to authenticated;
