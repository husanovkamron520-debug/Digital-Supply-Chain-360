-- Competition RPC repairs: load target records before checking their state.
-- Also ensure leaderboard views run with the querying user's privileges and RLS.

CREATE OR REPLACE FUNCTION public.competition_create_purchase_order(p_team_id uuid, p_supplier_id uuid, p_sku text, p_item_name text, p_quantity integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_team public.competition_teams%rowtype;
 v_supplier public.competition_suppliers%rowtype;
 v_clock public.competition_simulation_clock%rowtype;
 v_id uuid; v_po text; v_expected timestamptz; v_available timestamptz;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['procurement']) then
  raise exception 'Only the assigned Procurement Manager can create purchase orders';
 end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id and team_id=p_team_id and active;
 if not found then raise exception 'Active supplier not found for this team'; end if;
 if p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Quantity must be 1-100,000'; end if;
 if char_length(trim(coalesce(p_sku,''))) not between 2 and 40 or char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 then
  raise exception 'Invalid SKU or item name';
 end if;
 v_expected:=v_clock.virtual_now+make_interval(days=>v_supplier.lead_time_days);
 v_available:=v_expected+make_interval(days=>greatest(0,round((100-v_supplier.reliability_score)/10.0)::integer));
 v_po:='PO-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.competition_purchase_orders(competition_id,team_id,classroom_id,supplier_id,po_number,sku,item_name,quantity,unit_cost,expected_at,available_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,v_supplier.id,v_po,upper(trim(p_sku)),trim(p_item_name),p_quantity,v_supplier.unit_cost,v_expected,v_available)
 returning id into v_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'procurement','purchase_order_placed','Purchase order '||v_po||' placed',
 jsonb_build_object('supplier',v_supplier.name,'quantity',p_quantity,'unit_cost',v_supplier.unit_cost,'lead_time_days',v_supplier.lead_time_days,
 'reliability_score',v_supplier.reliability_score,'expected_at',v_expected,'available_at',v_available));
 return v_id;
end; $function$
;

CREATE OR REPLACE FUNCTION public.competition_deliver_shipment(p_shipment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_ship public.competition_shipments%rowtype;
 v_order public.competition_customer_orders%rowtype;
 v_delivered integer; v_revenue numeric;
 v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_ship from public.competition_shipments where id=p_shipment_id for update;
 if not found then raise exception 'Shipment not found'; end if;
 if not exists(select 1 from public.competitions where id=v_ship.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_ship.competition_id,v_ship.team_id,array['transport']) then
  raise exception 'Only the assigned Transport Manager can confirm delivery';
 end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_ship.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
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
end; $function$
;

CREATE OR REPLACE FUNCTION public.competition_dispatch_shipment(p_order_id uuid, p_quantity integer, p_origin text, p_destination text, p_carrier text, p_transport_cost numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_order public.competition_customer_orders%rowtype;
 v_stock integer; v_shipped integer; v_id uuid; v_cash numeric;
 v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not exists(select 1 from public.competitions where id=v_order.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then
  raise exception 'Only the assigned Transport Manager can dispatch shipments';
 end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 if v_order.status in('cancelled','delivered') then raise exception 'This customer order cannot be shipped'; end if;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then
  raise exception 'Invalid shipment details';
 end if;
 if p_transport_cost is null or p_transport_cost<0 or p_transport_cost>10000000 then raise exception 'Invalid transport cost'; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 if v_shipped+p_quantity>v_order.quantity then raise exception 'Shipment quantity exceeds the outstanding customer order'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 select cash_balance into v_cash from public.competition_teams where id=v_order.team_id for update;
 if v_cash<p_transport_cost then raise exception 'Insufficient company cash for transport'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta,dispatched_at)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,trim(p_origin),trim(p_destination),trim(p_carrier),p_transport_cost,v_clock.virtual_now+interval '2 days',v_clock.virtual_now)
 returning id into v_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-p_transport_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-p_transport_cost,'Shipment transport cost',v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','shipment_dispatched','Dispatched '||p_quantity||' units to '||p_destination,
 jsonb_build_object('shipment_id',v_id,'order_id',p_order_id,'stock_after',v_stock-p_quantity,'transport_cost',p_transport_cost,'eta',v_clock.virtual_now+interval '2 days'));
 return v_id;
end; $function$
;

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
 v_new integer; v_stock integer; v_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not exists(select 1 from public.competitions where id=v_po.competition_id and status='active') then
  raise exception 'Competition is not active';
 end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then
  raise exception 'Only the assigned Warehouse Manager can receive stock';
 end if;
 if v_po.status in('cancelled','received') then raise exception 'Purchase order cannot be received'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_po.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
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
end; $function$
;

CREATE OR REPLACE FUNCTION public.submit_competition_task(p_task_id uuid, p_submission jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_task public.competition_tasks%rowtype; v_role text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
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
  submitted_round=(select current_round from public.competition_simulation_clock where competition_id=v_task.competition_id)
 where id=p_task_id;
 return p_task_id;
end; $function$
;

revoke all on function public.competition_create_purchase_order(uuid,uuid,text,text,integer) from public,anon; grant execute on function public.competition_create_purchase_order(uuid,uuid,text,text,integer) to authenticated;
revoke all on function public.competition_receive_purchase_order(uuid,integer) from public,anon; grant execute on function public.competition_receive_purchase_order(uuid,integer) to authenticated;
revoke all on function public.competition_dispatch_shipment(uuid,integer,text,text,text,numeric) from public,anon; grant execute on function public.competition_dispatch_shipment(uuid,integer,text,text,text,numeric) to authenticated;
revoke all on function public.competition_deliver_shipment(uuid) from public,anon; grant execute on function public.competition_deliver_shipment(uuid) to authenticated;
revoke all on function public.submit_competition_task(uuid,jsonb) from public,anon; grant execute on function public.submit_competition_task(uuid,jsonb) to authenticated;

alter view public.competition_public_leaderboard set (security_invoker = true);
alter view public.competition_individual_leaderboard set (security_invoker = true);
