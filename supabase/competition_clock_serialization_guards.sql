CREATE OR REPLACE FUNCTION public.competition_receive_purchase_order(p_purchase_order_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_po public.competition_purchase_orders%rowtype;
 v_team public.competition_teams%rowtype;
 v_clock public.competition_simulation_clock%rowtype;
 v_new integer; v_stock integer; v_cost numeric; v_competition_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_purchase_orders where id=p_purchase_order_id;
 if not found then raise exception 'Purchase order not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if v_po.competition_id<>v_competition_id then raise exception 'Purchase order competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_po.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then
  raise exception 'Only the assigned Warehouse Manager can receive stock';
 end if;
 if v_po.status in('cancelled','received') then raise exception 'Purchase order cannot be received'; end if;
 if v_clock.virtual_now<coalesce(v_po.available_at,v_po.expected_at) then
  raise exception 'Supplier delivery is not available yet. Expected date: %, reliability-adjusted availability: %',v_po.expected_at,coalesce(v_po.available_at,v_po.expected_at);
 end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 v_cost:=p_quantity*v_po.unit_cost;
 select * into v_team from public.competition_teams where id=v_po.team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash to pay for this receipt'; end if;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_po.item_name,'raw_material',p_quantity,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set
  unit_cost=case when public.competition_inventory.quantity+excluded.quantity>0
   then round((public.competition_inventory.quantity*public.competition_inventory.unit_cost+excluded.quantity*excluded.unit_cost)/
    (public.competition_inventory.quantity+excluded.quantity),2) else excluded.unit_cost end,
  quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new:=v_po.received_quantity+p_quantity;
 update public.competition_purchase_orders set received_quantity=v_new,status=case when v_new=quantity then 'received' else 'partially_received' end,
  received_at=case when v_new=quantity then v_clock.virtual_now else received_at end where id=p_purchase_order_id;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'purchase',-v_cost,'Received '||p_quantity||' units of '||v_po.sku,p_purchase_order_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'warehouse','purchase_order_received','Received '||p_quantity||' units of '||v_po.sku,
 jsonb_build_object('stock_after',v_stock,'cost',v_cost,'po_id',p_purchase_order_id,'virtual_received_at',v_clock.virtual_now));
 return jsonb_build_object('received_quantity',v_new,'stock_quantity',v_stock,'cost',v_cost,'virtual_received_at',v_clock.virtual_now);
end; $function$;
revoke all on function public.competition_receive_purchase_order(uuid,integer) from public,anon;
grant execute on function public.competition_receive_purchase_order(uuid,integer) to authenticated;

CREATE OR REPLACE FUNCTION public.competition_deliver_shipment(p_shipment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_ship public.competition_shipments%rowtype;
 v_order public.competition_customer_orders%rowtype;
 v_delivered integer; v_revenue numeric; v_competition_id uuid;
 v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_shipments where id=p_shipment_id;
 if not found then raise exception 'Shipment not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_ship from public.competition_shipments where id=p_shipment_id for update;
 if not found then raise exception 'Shipment not found'; end if;
 if v_ship.competition_id<>v_competition_id then raise exception 'Shipment competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_ship.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_ship.competition_id,v_ship.team_id,array['transport']) then
  raise exception 'Only the assigned Transport Manager can confirm delivery';
 end if;
 if v_ship.status='delivered' then raise exception 'Shipment is already delivered'; end if;
 if v_ship.status='cancelled' then raise exception 'Cancelled shipment cannot be delivered'; end if;
 if v_clock.virtual_now<v_ship.eta then raise exception 'Shipment is still in transit. Estimated arrival: %',v_ship.eta; end if;
 select * into v_order from public.competition_customer_orders where id=v_ship.order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 update public.competition_shipments set status='delivered',delivered_at=v_clock.virtual_now where id=p_shipment_id;
 select coalesce(sum(quantity),0) into v_delivered from public.competition_shipments where order_id=v_ship.order_id and status='delivered';
 if v_delivered>=v_order.quantity then
  update public.competition_customer_orders set status='delivered',delivered_at=v_clock.virtual_now where id=v_order.id;
 else
  update public.competition_customer_orders set status='partially_shipped' where id=v_order.id;
 end if;
 v_revenue:=v_ship.quantity*v_order.unit_price;
 update public.competition_teams set cash_balance=cash_balance+v_revenue where id=v_ship.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'revenue',v_revenue,'Customer delivery revenue',p_shipment_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'transport','shipment_delivered','Shipment delivered to '||v_ship.destination,
 jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',v_clock.virtual_now<=v_order.due_at,'revenue',v_revenue));
 return jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',v_clock.virtual_now<=v_order.due_at,'revenue',v_revenue,'virtual_delivered_at',v_clock.virtual_now);
end; $function$;
revoke all on function public.competition_deliver_shipment(uuid) from public,anon;
grant execute on function public.competition_deliver_shipment(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.competition_update_supplier_terms(p_supplier_id uuid, p_lead_time_days integer, p_unit_cost numeric, p_reliability_score numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_supplier public.competition_suppliers%rowtype;
 v_clock public.competition_simulation_clock%rowtype; v_competition_id uuid;
 v_min_lead integer; v_max_lead integer; v_min_cost numeric; v_max_cost numeric;
 v_min_reliability numeric; v_max_reliability numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_suppliers where id=p_supplier_id;
 if not found then raise exception 'Supplier not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id for update;
 if not found then raise exception 'Supplier not found'; end if;
 if v_supplier.competition_id<>v_competition_id then raise exception 'Supplier competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_supplier.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if v_clock.current_round>=v_clock.round_limit then raise exception 'Supplier negotiations are closed in the final round'; end if;
 if not public.is_competition_role(v_supplier.competition_id,v_supplier.team_id,array['supplier','procurement']) then
  raise exception 'Only Supplier Relations or Procurement can negotiate supplier terms';
 end if;
 v_min_lead:=greatest(1,floor(v_supplier.base_lead_time_days*0.7)::integer);
 v_max_lead:=least(90,ceil(v_supplier.base_lead_time_days*1.5)::integer);
 v_min_cost:=round(v_supplier.base_unit_cost*0.8,2);
 v_max_cost:=round(v_supplier.base_unit_cost*1.25,2);
 v_min_reliability:=greatest(50,v_supplier.base_reliability_score-10);
 v_max_reliability:=least(99,v_supplier.base_reliability_score+5);
 if p_lead_time_days is null or p_lead_time_days not between v_min_lead and v_max_lead then
  raise exception 'Lead time must stay within %–% days for this supplier',v_min_lead,v_max_lead;
 end if;
 if p_unit_cost is null or p_unit_cost not between v_min_cost and v_max_cost then
  raise exception 'Unit cost must stay within %–% for this supplier',v_min_cost,v_max_cost;
 end if;
 if p_reliability_score is null or p_reliability_score not between v_min_reliability and v_max_reliability then
  raise exception 'Reliability must stay within %–% for this supplier',v_min_reliability,v_max_reliability;
 end if;
 if p_unit_cost<=v_supplier.base_unit_cost
   and p_lead_time_days<=v_supplier.base_lead_time_days
   and p_reliability_score>=v_supplier.base_reliability_score
   and (p_unit_cost<v_supplier.base_unit_cost or p_lead_time_days<v_supplier.base_lead_time_days or p_reliability_score>v_supplier.base_reliability_score) then
  raise exception 'A supplier cannot improve price, speed and reliability all at once. Trade one term against another or pay a premium.';
 end if;
 update public.competition_suppliers set lead_time_days=p_lead_time_days,unit_cost=p_unit_cost,reliability_score=p_reliability_score where id=p_supplier_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_supplier.competition_id,v_supplier.team_id,v_supplier.classroom_id,(select auth.uid()),'supplier','supplier_terms_updated',
  'Supplier terms negotiated: '||v_supplier.name,jsonb_build_object('supplier_id',p_supplier_id,
  'lead_time_days',p_lead_time_days,'unit_cost',p_unit_cost,'reliability',p_reliability_score,
  'baseline',jsonb_build_object('lead_time_days',v_supplier.base_lead_time_days,'unit_cost',v_supplier.base_unit_cost,'reliability',v_supplier.base_reliability_score)));
 return true;
end; $function$;
revoke all on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) from public,anon;
grant execute on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.competition_adjust_inventory(p_team_id uuid, p_sku text, p_delta integer, p_reason text DEFAULT 'Cycle count'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_competition_id uuid; v_qty integer; v_current integer; v_max_delta integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if v_team.competition_id<>v_competition_id then raise exception 'Team competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['warehouse']) then raise exception 'Only the Warehouse Manager can adjust stock'; end if;
 if p_delta is null or p_delta=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 if char_length(trim(coalesce(p_reason,''))) not between 5 and 300 then raise exception 'Provide a clear cycle-count reason (5-300 characters)'; end if;
 select quantity into v_current from public.competition_inventory
 where team_id=p_team_id and sku=upper(trim(p_sku)) for update;
 if not found then raise exception 'SKU not found'; end if;
 v_max_delta:=greatest(1,floor(v_current*0.05)::integer);
 if abs(p_delta)>v_max_delta then
  raise exception 'Cycle-count adjustment exceeds the 5%% tolerance: maximum allowed change is % units',v_max_delta;
 end if;
 update public.competition_inventory set quantity=quantity+p_delta,updated_at=now()
 where team_id=p_team_id and sku=upper(trim(p_sku)) and quantity+p_delta>=0 returning quantity into v_qty;
 if not found then raise exception 'Adjustment would make stock negative'; end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'warehouse','inventory_adjusted','Stock adjusted: '||p_sku,
 jsonb_build_object('delta',p_delta,'quantity_before',v_current,'quantity_after',v_qty,'reason',trim(p_reason),'max_allowed_delta',v_max_delta));
 return v_qty;
end; $function$;
revoke all on function public.competition_adjust_inventory(uuid,text,integer,text) from public,anon;
grant execute on function public.competition_adjust_inventory(uuid,text,integer,text) to authenticated;

CREATE OR REPLACE FUNCTION public.submit_competition_task(p_task_id uuid, p_submission jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_task public.competition_tasks%rowtype; v_role text;
 v_clock public.competition_simulation_clock%rowtype; v_competition_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_tasks where id=p_task_id;
 if not found then raise exception 'Task not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
 if v_task.competition_id<>v_competition_id then raise exception 'Task competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_task.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if v_task.status not in ('pending','in_progress','rejected') then raise exception 'Task cannot be submitted in its current state'; end if;
 select operational_role into v_role from public.competition_team_members
 where competition_id=v_task.competition_id and team_id=v_task.team_id and student_id=(select auth.uid());
 if not found then raise exception 'You are not a member of this team'; end if;
 if v_task.assigned_to is not null and v_task.assigned_to <> (select auth.uid()) then raise exception 'This task is assigned to another student'; end if;
 if v_task.assigned_role is not null and v_task.assigned_role <> v_role then raise exception 'This task is assigned to another role'; end if;
 if jsonb_typeof(p_submission) <> 'object' then raise exception 'Submission must be a JSON object'; end if;
 if length(p_submission::text)>12000 then raise exception 'Submission is too large'; end if;
 update public.competition_tasks set status='submitted',submission=p_submission,submitted_at=now(),
  submitted_round=v_clock.current_round
 where id=p_task_id;
 return p_task_id;
end; $function$;
revoke all on function public.submit_competition_task(uuid,jsonb) from public,anon;
grant execute on function public.submit_competition_task(uuid,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.record_competition_decision(p_competition_id uuid, p_team_id uuid, p_domain text, p_decision_type text, p_selected_option text, p_rationale text, p_inputs jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_status text; v_id uuid; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select status into v_status from public.competitions where id=p_competition_id;
 if v_status <> 'active' then raise exception 'Competition is not active'; end if;
 if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=p_team_id and student_id=(select auth.uid())) then raise exception 'You are not a member of this team'; end if;
 if p_domain not in ('procurement','inventory','production','transport','customer_service','finance','risk','strategy') then raise exception 'Unsupported decision domain'; end if;
 if char_length(trim(coalesce(p_decision_type,''))) not between 2 and 80 then raise exception 'Invalid decision type'; end if;
 if char_length(trim(coalesce(p_selected_option,''))) not between 1 and 120 then raise exception 'Select a valid option'; end if;
 if char_length(trim(coalesce(p_rationale,''))) not between 20 and 2000 then raise exception 'Explain your decision in at least 20 characters'; end if;
 if jsonb_typeof(coalesce(p_inputs,'{}'::jsonb)) <> 'object' then raise exception 'Decision inputs must be a JSON object'; end if;
 insert into public.competition_decisions(competition_id,team_id,classroom_id,student_id,domain,decision_type,selected_option,rationale,inputs)
 values(p_competition_id,p_team_id,v_classroom_id,(select auth.uid()),p_domain,trim(p_decision_type),trim(p_selected_option),trim(p_rationale),coalesce(p_inputs,'{}'::jsonb))
 returning id into v_id;
 return v_id;
end;
$function$;
revoke all on function public.record_competition_decision(uuid,uuid,text,text,text,text,jsonb) from public,anon;
grant execute on function public.record_competition_decision(uuid,uuid,text,text,text,text,jsonb) to authenticated;

CREATE OR REPLACE FUNCTION public.evaluate_competition_decision(p_decision_id uuid, p_score numeric, p_feedback text DEFAULT ''::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_competition_id uuid; v_status text; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_decisions where id=p_decision_id;
 if not found then raise exception 'Decision not found'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select classroom_id into v_classroom_id from public.competition_decisions where id=p_decision_id for update;
 if not found then raise exception 'Decision not found'; end if;
 select status into v_status from public.competitions where id=v_competition_id;
 if v_status not in ('active','paused') then raise exception 'Decisions can only be evaluated before the competition is completed'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can evaluate decisions'; end if;
 if p_score is null or p_score<0 or p_score>100 then raise exception 'Score must be between 0 and 100'; end if;
 update public.competition_decisions set score=round(p_score,2),feedback=left(coalesce(p_feedback,''),2000),
  evaluated_by=(select auth.uid()),evaluated_at=now() where id=p_decision_id;
 return true;
end; $function$;
revoke all on function public.evaluate_competition_decision(uuid,numeric,text) from public,anon;
grant execute on function public.evaluate_competition_decision(uuid,numeric,text) to authenticated;
