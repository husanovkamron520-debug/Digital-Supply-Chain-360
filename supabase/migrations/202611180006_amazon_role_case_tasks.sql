
create or replace function public.amazon_create_role_tasks(p_competition_id uuid)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_classroom uuid; v_status text; v_team record; v_member record; v_count integer:=0; v_title text; v_description text; v_priority text; v_due_round integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom,v_status from public.competitions where id=p_competition_id for update;
 if not found or not public.is_class_teacher(v_classroom) then raise exception 'Only the teacher can create Amazon role tasks'; end if;
 if v_status not in ('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if coalesce((select settings->>'case_code' from public.competitions where id=p_competition_id),'')<>'amazon-global-combined-crisis' then raise exception 'Not an Amazon case'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then raise exception 'Role tasks already exist'; end if;
 for v_team in select id,name from public.competition_teams where competition_id=p_competition_id loop
  for v_member in select student_id,operational_role from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id loop
   if v_member.operational_role='procurement' then
    v_title:='Procurement control tower: 30-day sourcing plan';v_priority:='critical';v_due_round:=1;
    v_description:='ROLE: Procurement Manager. CASE: Amazon Global Combined Crisis (fictional educational simulation). Mission: cover 9,800 units of crisis demand across five SKUs, starting with 1,850 units of inventory, while demand is +40% and Supplier A (China) is delayed by 10 extra days (22-day crisis lead time). You control supplier allocation, PO quantities, order day, price and the $160,000 main procurement budget. A separate $30,000 reserve requires team approval. Supplier A/B/C have SKU-specific MOQ, capacity and prices shown in the live case panel. Build a feasible SKU-by-SKU sourcing plan; compare total cost and arrival dates; ensure all needed stock arrives by Day 30. Select Cost-focused (A >=60%), Balanced (A 40–70%) or Service-focused (B+C >=60%). Any strategy change and reserve draw require team approval. Explain your allocation, budget headroom, risk and contingency for each of the three 10-day rounds. Do not invent supplier commitments.';
   elsif v_member.operational_role='supplier' then
    v_title:='Supplier relationship and SLA recovery plan';v_priority:='high';v_due_round:=1;
    v_description:='ROLE: Supplier Relations Manager. Manage Supplier A (China, 22-day crisis lead, 90% OTIF, 2.5% defects), Supplier B (Germany, 8 days, 96% OTIF, 1% defects) and Supplier C (USA, 5 days, 98% OTIF, 0.5% defects). All case data are synthetic. Prepare a supplier scorecard; identify the impact of the 10-day A delay; define confirmation checkpoints, escalation triggers, recovery commitments, quality controls and alternative-source communication. Do not change Procurement allocation or override SKU capacity/MOQ. Submit a written supplier recovery brief with quantified service and cost consequences.';
   elsif v_member.operational_role='manufacturer' then
    v_title:='Fulfillment operations: pick, pack and backlog recovery';v_priority:='critical';v_due_round:=2;
    v_description:='ROLE: Fulfillment Operations Manager (not a manufacturer). There is no production in this case. Manage order prioritisation, pick waves, packing accuracy, release-to-transport and backlog recovery. Use only received finished-goods inventory. The live workflow limits release to available stock and 1,500 units of throughput per round. Prioritise due dates and high-risk orders; coordinate with Warehouse on availability and Transport on dispatch capacity. Submit a pick/pack wave plan, explain prioritisation rules, and quantify how many units can be safely released in each 10-day round.';
   elsif v_member.operational_role='warehouse' then
    v_title:='Warehouse control: receiving, storage and inventory accuracy';v_priority:='critical';v_due_round:=2;
    v_description:='ROLE: Warehouse Manager. Control inbound receiving, put-away, storage, inventory accuracy and pick-face availability. Opening finished-goods stock is 1,850 units across five SKUs. Receive purchase orders only at their virtual ETA; validate SKU and quantity, update available stock, and coordinate release reservations with Fulfillment. Provisional warehouse capacity is 8,000 units and can be tuned by the teacher. Design receiving priorities, cycle-count controls, capacity protection and exception escalation. Never receive an unavailable or unplaced PO.';
   else
    v_title:='Transport execution: dispatch, routing and OTIF';v_priority:='high';v_due_round:=3;
    v_description:='ROLE: Transport Manager. Dispatch only quantities released by Fulfillment Operations. Plan carrier capacity, dispatch sequence, lane choice and delivery confirmation. Outbound standard transit is two virtual days at the synthetic $2.50/unit benchmark. Respect ready-to-dispatch quantities, inventory, order balance and Day 30 horizon. Prioritise due orders, track in-transit shipments, confirm delivery only after ETA, and report on-time-in-full performance, freight spend and exceptions. Submit a dispatch wave and contingency plan.';
   end if;
   insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_to,assigned_role,title,description,priority,due_at,due_round,created_by)
   values(p_competition_id,v_team.id,v_classroom,v_member.student_id,v_member.operational_role,v_title,v_description,v_priority,null,v_due_round,(select auth.uid()));
   v_count:=v_count+1;
  end loop;
 end loop;
 return v_count;
end; $$;
grant execute on function public.amazon_create_role_tasks(uuid) to authenticated;
