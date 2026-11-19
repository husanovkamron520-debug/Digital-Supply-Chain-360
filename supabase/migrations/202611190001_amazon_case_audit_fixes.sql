-- Amazon Global Combined Crisis: operational, financial and team-data audit fixes
-- Safe to apply repeatedly. No competition/team rows are modified.
ALTER TABLE public.competitions ADD COLUMN IF NOT EXISTS paused_at timestamptz;

CREATE OR REPLACE FUNCTION public.amazon_assert_round_open(p_competition_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v_status text; v_round integer; v_ends timestamptz;
BEGIN
 SELECT status INTO v_status FROM public.competitions WHERE id=p_competition_id AND settings->>'case_code'='amazon-global-combined-crisis';
 IF NOT FOUND OR v_status<>'active' THEN RAISE EXCEPTION 'Amazon case is not active'; END IF;
 SELECT current_round INTO v_round FROM public.competition_simulation_clock WHERE competition_id=p_competition_id;
 SELECT ends_at INTO v_ends FROM public.competition_rounds WHERE competition_id=p_competition_id AND round_number=v_round AND status='active';
 IF v_ends IS NULL OR now()>=v_ends THEN RAISE EXCEPTION 'This round has closed. Ask the teacher to advance or resume the simulation.'; END IF;
END; $$;
REVOKE ALL ON FUNCTION public.amazon_assert_round_open(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.amazon_assert_round_open(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.is_competition_team_member(p_team_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.competition_team_members m WHERE m.team_id=p_team_id AND m.student_id=(select auth.uid())) $$;
REVOKE ALL ON FUNCTION public.is_competition_team_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_competition_team_member(uuid) TO authenticated;

DROP POLICY IF EXISTS competition_teams_read_competition ON public.competition_teams;
CREATE POLICY competition_teams_read_competition ON public.competition_teams FOR SELECT TO authenticated
USING (public.is_class_teacher(classroom_id) OR public.is_competition_team_member(id));
ALTER VIEW public.competition_team_live_metrics SET (security_invoker=true);

CREATE OR REPLACE FUNCTION public.amazon_place_purchase_order(p_team_id uuid, p_supplier_code text, p_sku text, p_quantity integer, p_order_day integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_clock public.competition_simulation_clock%rowtype; v_team public.competition_teams%rowtype;
 v_comp public.competitions%rowtype; v_offer public.amazon_case_supplier_offers%rowtype;
 v_supplier_id uuid; v_id uuid; v_spend numeric; v_arrival timestamptz; v_day integer;
 v_state public.amazon_case_team_state%rowtype; v_mix numeric; v_total integer; v_a integer; v_bc integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 select * into v_comp from public.competitions where id=v_team.competition_id;
 if v_comp.status<>'active' or coalesce(v_comp.settings->>'case_code','')<>'amazon-global-combined-crisis' then raise exception 'Amazon competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,p_team_id,array['procurement']) then raise exception 'Only Procurement Manager can place orders'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id for update;
 perform public.amazon_assert_round_open(v_team.competition_id);
 select * into v_state from public.amazon_case_team_state where team_id=p_team_id for update;
 if v_clock.current_round>3 then raise exception '30-day horizon has ended'; end if;
 select * into v_offer from public.amazon_case_supplier_offers where team_id=p_team_id and supplier_code=p_supplier_code and sku=upper(p_sku);
 if not found then raise exception 'Supplier offer/SKU not found'; end if;
 if p_quantity is null or p_quantity<v_offer.moq then raise exception 'Order quantity is below MOQ (%)',v_offer.moq; end if;
 select coalesce(sum(quantity),0) into v_total from public.competition_purchase_orders where team_id=p_team_id and sku=upper(p_sku) and supplier_id=v_offer.supplier_id and status<>'cancelled';
 if v_total+p_quantity>v_offer.max_capacity then raise exception 'Supplier capacity exceeded for this SKU'; end if;
 v_day:=coalesce(p_order_day,(v_clock.current_round-1)*10+1);
 if v_day<((v_clock.current_round-1)*10+1) or v_day>v_clock.current_round*10 then raise exception 'Order day must be inside the current 10-day round'; end if;
 v_arrival:=v_clock.virtual_now+make_interval(days=>(v_day-((v_clock.current_round-1)*10+1))+v_offer.lead_time_days);
 if v_arrival>v_clock.virtual_now+make_interval(days=>greatest(0,3-v_clock.current_round)*10+9) then raise exception 'Arrival is outside the 30-day case horizon'; end if;
 v_spend:=p_quantity*v_offer.unit_price;
 if v_state.committed_spend+v_spend>v_state.main_budget+v_state.reserve_approved then raise exception 'Procurement budget exceeded. Main budget is $160,000; reserve requires team approval'; end if;
 insert into public.competition_purchase_orders(competition_id,team_id,classroom_id,supplier_id,po_number,sku,item_name,quantity,unit_cost,expected_at,available_at)
 select v_team.competition_id,p_team_id,v_team.classroom_id,v_offer.supplier_id,
  'AMZ-PO-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),v_offer.sku,s.item_name,p_quantity,v_offer.unit_price,v_arrival,v_arrival
 from public.amazon_case_skus s where s.sku=v_offer.sku returning id into v_id;
 update public.amazon_case_team_state set committed_spend=committed_spend+v_spend where team_id=p_team_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,p_team_id,v_team.classroom_id,(select auth.uid()),'procurement','amazon_purchase_order',
 'Amazon procurement order submitted',jsonb_build_object('supplier_code',p_supplier_code,'sku',p_sku,'quantity',p_quantity,'unit_price',v_offer.unit_price,'committed_cost',v_spend,'eta',v_arrival,'order_day',v_day));
 return v_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_receive_purchase_order(p_purchase_order_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_po public.competition_purchase_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_new integer; v_stock integer; v_cost numeric; v_item text; v_capacity integer; v_occupied integer;
 v_defect_rate numeric; v_defective integer; v_usable integer; v_supplier_code text; v_prior_defective integer; v_cash numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_po.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 if v_po.status in ('cancelled','received') then raise exception 'This purchase order cannot be received'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only Warehouse Manager can receive stock'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_po.competition_id for update;
 perform public.amazon_assert_round_open(v_po.competition_id);
 if coalesce(v_po.available_at,v_po.expected_at)>v_clock.virtual_now+interval '9 days' then raise exception 'Supplier ETA is outside the current 10-day round window'; end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 select item_name into v_item from public.amazon_case_skus where sku=v_po.sku;
 select defect_rate_pct,supplier_code into v_defect_rate,v_supplier_code
 from public.amazon_case_supplier_offers where team_id=v_po.team_id and supplier_id=v_po.supplier_id and sku=v_po.sku;
 v_prior_defective:=ceil(v_po.received_quantity*coalesce(v_defect_rate,0)/100.0)::integer;
 v_defective:=least(p_quantity,greatest(0,ceil((v_po.received_quantity+p_quantity)*coalesce(v_defect_rate,0)/100.0)::integer-v_prior_defective));
 v_usable:=p_quantity-v_defective;
 select warehouse_capacity_units into v_capacity from public.amazon_case_team_state where team_id=v_po.team_id;
 select coalesce((select sum(quantity) from public.competition_inventory where team_id=v_po.team_id),0)
   +coalesce((select sum(defective_quantity-disposed_quantity) from public.amazon_case_quality_receipts where team_id=v_po.team_id),0)
  into v_occupied;
 if v_occupied+p_quantity>v_capacity then raise exception 'Warehouse capacity exceeded: available headroom is % units',greatest(0,v_capacity-v_occupied); end if;
 v_cost:=p_quantity*v_po.unit_cost;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id and cash_balance>=v_cost returning cash_balance into v_cash;
 if not found then raise exception 'Insufficient cash to receive this purchase order'; end if;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_item,'finished_goods',v_usable,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set
  unit_cost=case when public.competition_inventory.quantity+excluded.quantity>0 then
   round((public.competition_inventory.quantity*public.competition_inventory.unit_cost+excluded.quantity*excluded.unit_cost)/
   (public.competition_inventory.quantity+excluded.quantity),2) else excluded.unit_cost end,
  quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new:=v_po.received_quantity+p_quantity;
 update public.competition_purchase_orders set received_quantity=v_new,status=case when v_new=quantity then 'received' else 'partially_received' end,
 received_at=case when v_new=quantity then coalesce(v_po.available_at,v_po.expected_at) else received_at end where id=p_purchase_order_id;
 insert into public.amazon_case_quality_receipts(purchase_order_id,competition_id,team_id,supplier_code,sku,received_quantity,defective_quantity,usable_quantity,defect_rate_pct)
 values(p_purchase_order_id,v_po.competition_id,v_po.team_id,v_supplier_code,v_po.sku,p_quantity,v_defective,v_usable,coalesce(v_defect_rate,0));
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'purchase',-v_cost,'Amazon finished goods received',p_purchase_order_id);
 return jsonb_build_object('received_quantity',v_new,'stock_quantity',v_stock,'cost',v_cost,
   'usable_quantity',v_usable,'defective_quantity',v_defective,'defect_rate_pct',v_defect_rate);
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_fulfill_order(p_order_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.competition_customer_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_stock integer; v_ready integer; v_shipped integer; v_round_total integer; v_cap integer; v_comp_status text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['manufacturer']) then
  raise exception 'Only Fulfillment Operations Manager can release an order for fulfilment'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id for update;
 perform public.amazon_assert_round_open(v_order.competition_id);
 select status into v_comp_status from public.competitions where id=v_order.competition_id;
 if not exists(select 1 from public.competitions c where c.id=v_order.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis') then raise exception 'This is not an Amazon case order'; end if;
 if v_comp_status<>'active' or v_clock.current_round>3 then raise exception 'Amazon case is not accepting fulfilment actions'; end if;
 if p_quantity is null or p_quantity<1 then raise exception 'Quantity must be positive'; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 select coalesce((select ready_quantity from public.amazon_case_fulfillment where order_id=p_order_id),0) into v_ready;
 if v_shipped+v_ready+p_quantity>v_order.quantity then raise exception 'Fulfilment quantity exceeds the outstanding order quantity'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock < (select coalesce(sum(f.ready_quantity),0) from public.amazon_case_fulfillment f join public.competition_customer_orders o on o.id=f.order_id where f.team_id=v_order.team_id and o.sku=v_order.sku)+p_quantity then
  raise exception 'Insufficient unallocated finished-goods inventory'; end if;
 select production_capacity_units into v_cap from public.competition_teams where id=v_order.team_id;
 select coalesce(sum(f.round_released_quantity),0) into v_round_total from public.amazon_case_fulfillment f
 where f.team_id=v_order.team_id and f.updated_round=v_clock.current_round;
 if v_round_total+p_quantity>v_cap then raise exception 'Fulfilment throughput capacity exceeded for this round'; end if;
 insert into public.amazon_case_fulfillment(order_id,team_id,ready_quantity,updated_round,round_released_quantity)
 values(p_order_id,v_order.team_id,p_quantity,v_clock.current_round,p_quantity)
 on conflict(order_id) do update set ready_quantity=amazon_case_fulfillment.ready_quantity+excluded.ready_quantity,
 round_released_quantity=case when amazon_case_fulfillment.updated_round=excluded.updated_round
  then amazon_case_fulfillment.round_released_quantity+excluded.round_released_quantity else excluded.round_released_quantity end,
 updated_round=excluded.updated_round,updated_at=now();
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'manufacturer','amazon_fulfilment_ready',
 'Order prepared for fulfilment',jsonb_build_object('order_id',p_order_id,'quantity',p_quantity,'round',v_clock.current_round));
 return jsonb_build_object('order_id',p_order_id,'ready_quantity',v_ready+p_quantity,'remaining_stock',v_stock-(select coalesce(sum(ready_quantity),0) from public.amazon_case_fulfillment where team_id=v_order.team_id));
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_dispatch_shipment_v2(p_order_id uuid, p_quantity integer, p_carrier text DEFAULT 'Regional carrier'::text, p_service_level text DEFAULT 'standard'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.competition_customer_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_ready integer; v_stock integer; v_cost numeric; v_unit_cost numeric; v_transit integer; v_eta timestamptz;
 v_id uuid; v_cash numeric; v_horizon timestamptz; v_capacity integer; v_used integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_order.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only Transport Manager can dispatch'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id for update;
 perform public.amazon_assert_round_open(v_order.competition_id);
 select coalesce((select ready_quantity from public.amazon_case_fulfillment where order_id=p_order_id for update),0) into v_ready;
 if p_quantity is null or p_quantity<1 or p_quantity>v_ready then raise exception 'Dispatch quantity exceeds packed and released quantity'; end if;
 if p_service_level not in ('economy','standard','express') then raise exception 'Choose Economy, Standard or Express service'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 if p_service_level='economy' then v_unit_cost:=1.75;v_transit:=3;v_capacity:=2500;
 elsif p_service_level='express' then v_unit_cost:=4.25;v_transit:=1;v_capacity:=1000;
 else v_unit_cost:=2.50;v_transit:=2;v_capacity:=2200; end if;
 select coalesce(sum(quantity),0) into v_used from public.amazon_case_transport_dispatches
 where team_id=v_order.team_id and round_number=v_clock.current_round and service_level=p_service_level;
 if v_used+p_quantity>v_capacity then raise exception '% service capacity exceeded for this round; remaining capacity % units',upper(p_service_level),greatest(0,v_capacity-v_used); end if;
 v_cost:=p_quantity*v_unit_cost;
 select cash_balance into v_cash from public.competition_teams where id=v_order.team_id for update;
 if v_cash<v_cost then raise exception 'Insufficient cash for outbound transport'; end if;
 v_eta:=v_clock.virtual_now+make_interval(days=>v_transit);
 v_horizon:=v_clock.virtual_now+interval '9 days';
 if v_eta>v_horizon then raise exception 'Shipment ETA falls outside the Day 30 horizon'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta,dispatched_at)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,'Fulfilment centre','Customer destination',
  coalesce(nullif(trim(p_carrier),''),'Regional carrier')||' · '||upper(p_service_level),v_cost,v_eta,v_clock.virtual_now) returning id into v_id;
 insert into public.amazon_case_transport_dispatches(shipment_id,team_id,service_level,round_number,quantity,unit_cost,transit_days)
 values(v_id,v_order.team_id,p_service_level,v_clock.current_round,p_quantity,v_unit_cost,v_transit);
 update public.amazon_case_fulfillment set ready_quantity=ready_quantity-p_quantity,updated_at=now() where order_id=p_order_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-v_cost,'Amazon outbound transport · '||p_service_level,v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','amazon_shipment_dispatched',
 'Amazon customer shipment dispatched',jsonb_build_object('shipment_id',v_id,'quantity',p_quantity,'cost',v_cost,'unit_cost',v_unit_cost,'service_level',p_service_level,'transit_days',v_transit,'eta',v_eta));
 return v_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_vote_approval(p_approval_id uuid, p_vote text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_a public.amazon_case_approvals%rowtype; v_member public.competition_team_members%rowtype;
 v_yes integer; v_no integer; v_required jsonb; v_missing integer; v_state public.amazon_case_team_state%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_vote not in ('approve','reject') then raise exception 'Vote must be approve or reject'; end if;
 select * into v_a from public.amazon_case_approvals where id=p_approval_id for update;
 if not found or v_a.status<>'pending' then raise exception 'Pending approval not found'; end if;
 perform public.amazon_assert_round_open(v_a.competition_id);
 if v_a.requested_by=(select auth.uid()) then raise exception 'Requester cannot approve their own request'; end if;
 select * into v_member from public.competition_team_members where team_id=v_a.team_id and student_id=(select auth.uid());
 if not found then raise exception 'Only team members can vote'; end if;
 insert into public.amazon_case_approval_votes(approval_id,student_id,vote) values(p_approval_id,(select auth.uid()),p_vote);
 select count(*) filter(where vote='approve'),count(*) filter(where vote='reject') into v_yes,v_no
 from public.amazon_case_approval_votes where approval_id=p_approval_id;
 v_required:=coalesce(v_a.payload->'affected_roles','[]'::jsonb);
 select count(*) into v_missing from jsonb_array_elements_text(v_required) r(role)
 where not exists(select 1 from public.amazon_case_approval_votes v join public.competition_team_members m on m.student_id=v.student_id and m.team_id=v_a.team_id
  where v.approval_id=p_approval_id and v.vote='approve' and m.operational_role=r.role);
 if v_no>=3 then
  update public.amazon_case_approvals set status='rejected',resolved_at=now() where id=p_approval_id;
 elsif v_yes>=3 and v_missing=0 then
  update public.amazon_case_approvals set status='approved',resolved_at=now() where id=p_approval_id;
  select * into v_state from public.amazon_case_team_state where team_id=v_a.team_id for update;
  if v_a.approval_type='reserve_draw' then
   if v_state.reserve_approved+coalesce((v_a.payload->>'amount')::numeric,0)>v_state.reserve_budget then raise exception 'Emergency reserve limit exceeded'; end if;
   update public.amazon_case_team_state set reserve_approved=reserve_approved+(v_a.payload->>'amount')::numeric where team_id=v_a.team_id;
   update public.competition_teams set cash_balance=cash_balance+(v_a.payload->>'amount')::numeric where id=v_a.team_id;
   insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
   select v_a.competition_id,v_a.team_id,t.classroom_id,(select auth.uid()),'capital',
    (v_a.payload->>'amount')::numeric,'Approved emergency reserve release',p_approval_id
   from public.competition_teams t where t.id=v_a.team_id;
  elsif v_a.approval_type='strategy_change' then
   update public.amazon_case_team_state set strategic_posture=v_a.payload->>'posture' where team_id=v_a.team_id;
  end if;
 end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
  select v_a.competition_id,v_a.team_id,t.classroom_id,(select auth.uid()),'approval','amazon_approval_vote',
   'Team member voted on approval request',jsonb_build_object('approval_id',p_approval_id,'vote',p_vote,
    'status',(select status from public.amazon_case_approvals where id=p_approval_id),'approve_votes',v_yes,'reject_votes',v_no)
  from public.competition_teams t where t.id=v_a.team_id;
 return jsonb_build_object('status',(select status from public.amazon_case_approvals where id=p_approval_id),'approve_votes',v_yes,'reject_votes',v_no,'affected_roles_pending',v_missing);
end; $function$;

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
 if exists(select 1 from public.competitions c where c.id=v_ship.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis') then
  perform public.amazon_assert_round_open(v_ship.competition_id);
  if v_ship.eta>v_clock.virtual_now+interval '9 days' then raise exception 'Shipment ETA is outside the current 10-day round window'; end if;
 else
  if v_clock.virtual_now<v_ship.eta then raise exception 'Shipment is still in transit. Estimated arrival: %',v_ship.eta; end if;
 end if;
 select * into v_order from public.competition_customer_orders where id=v_ship.order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 update public.competition_shipments set status='delivered',delivered_at=case when exists(select 1 from public.competitions c where c.id=v_ship.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis') then greatest(v_clock.virtual_now,v_ship.eta) else v_clock.virtual_now end where id=p_shipment_id;
 select coalesce(sum(quantity),0) into v_delivered from public.competition_shipments where order_id=v_ship.order_id and status='delivered';
 if v_delivered>=v_order.quantity then
  update public.competition_customer_orders set status='delivered',delivered_at=case when exists(select 1 from public.competitions c where c.id=v_ship.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis') then greatest(v_clock.virtual_now,v_ship.eta) else v_clock.virtual_now end where id=v_order.id;
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
 if exists(select 1 from public.competitions where id=v_team.competition_id and settings->>'case_code'='amazon-global-combined-crisis') then raise exception 'Manual stock adjustments are disabled in Amazon case. Use purchase-order receipt and quality workflows.'; end if;
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

CREATE OR REPLACE FUNCTION public.create_competition_team(p_competition_id uuid, p_team_name text, p_company_template_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_id uuid; v_status text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can create teams'; end if;
 if v_status <> 'draft' then raise exception 'Teams can only be configured while competition is in draft'; end if;
 if char_length(trim(coalesce(p_team_name,''))) not between 2 and 80 then raise exception 'Team name must be 2-80 characters'; end if;
 if not exists(select 1 from public.company_templates where id=p_company_template_id and active) then raise exception 'Active company template not found'; end if;
 if exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='amazon-global-combined-crisis') and not exists(select 1 from public.company_templates where id=p_company_template_id and slug='amazon-global-combined-crisis') then raise exception 'Amazon competition teams must use the Amazon Global Combined Crisis template'; end if;
 if (select count(*) from public.competition_teams where competition_id=p_competition_id)>=4 then raise exception 'A competition can have at most four teams'; end if;
 insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
 values(p_competition_id,v_classroom_id,p_company_template_id,trim(p_team_name))
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Team name already exists in this competition';
end;
$function$;

CREATE OR REPLACE FUNCTION public.amazon_get_case_data(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_state public.amazon_case_team_state%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competition_team_members where team_id=p_team_id and student_id=(select auth.uid()))
    and not public.is_class_teacher(v_team.classroom_id) then raise exception 'You are not a member of this team'; end if;
 select * into v_state from public.amazon_case_team_state where team_id=p_team_id;
 if not found then raise exception 'Amazon case team is not initialized'; end if;
 return jsonb_build_object(
  'state',to_jsonb(v_state),
  'skus',(select jsonb_agg(to_jsonb(s) order by s.sku) from public.amazon_case_skus s),
  'offers',(select jsonb_agg(jsonb_build_object('supplier_code',o.supplier_code,'supplier_name',cs.name,'sku',o.sku,'unit_price',o.unit_price,'moq',o.moq,'max_capacity',o.max_capacity,'lead_time_days',o.lead_time_days,'otif_pct',o.otif_pct,'defect_rate_pct',o.defect_rate_pct) order by o.sku,o.supplier_code)
   from public.amazon_case_supplier_offers o join public.competition_suppliers cs on cs.id=o.supplier_id where o.team_id=p_team_id),
  'fulfilment',(select coalesce(jsonb_agg(jsonb_build_object('order_id',f.order_id,'ready_quantity',f.ready_quantity,'updated_round',f.updated_round)),'[]'::jsonb) from public.amazon_case_fulfillment f where f.team_id=p_team_id),
  'quality_receipts',(select coalesce(jsonb_agg(to_jsonb(qr) order by qr.created_at desc),'[]'::jsonb) from public.amazon_case_quality_receipts qr where qr.team_id=p_team_id),
  'commitments',(select coalesce(jsonb_agg(to_jsonb(sc) order by sc.created_at desc),'[]'::jsonb) from public.amazon_case_supplier_commitments sc where sc.team_id=p_team_id),
  'approvals',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'approval_type',a.approval_type,'reason',a.reason,'payload',a.payload,'requested_by',a.requested_by,'status',a.status,
   'approve_votes',(select count(*) from public.amazon_case_approval_votes v where v.approval_id=a.id and v.vote='approve'),
   'reject_votes',(select count(*) from public.amazon_case_approval_votes v where v.approval_id=a.id and v.vote='reject'),
   'votes',(select coalesce(jsonb_agg(jsonb_build_object('student_id',v.student_id,'role',m.operational_role,'vote',v.vote,'created_at',v.created_at) order by v.created_at),'[]'::jsonb) from public.amazon_case_approval_votes v join public.competition_team_members m on m.student_id=v.student_id and m.team_id=a.team_id where v.approval_id=a.id))),'[]'::jsonb) from public.amazon_case_approvals a where a.team_id=p_team_id)
 );
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_initialize_team(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_comp public.competitions%rowtype;
 v_supplier_a uuid; v_supplier_b uuid; v_supplier_c uuid; v_sku record; v_order_qty integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 select * into v_comp from public.competitions where id=v_team.competition_id;
 if not public.is_class_teacher(v_team.classroom_id) then raise exception 'Only the teacher can initialise the Amazon case'; end if;
 if coalesce(v_comp.settings->>'case_code','')<>'amazon-global-combined-crisis' then raise exception 'This is not an Amazon Global Combined Crisis competition'; end if;
 if exists(select 1 from public.amazon_case_team_state where team_id=p_team_id) then
   return jsonb_build_object('team_id',p_team_id,'already_initialized',true);
 end if;
 delete from public.competition_customer_orders where team_id=p_team_id;
 delete from public.competition_purchase_orders where team_id=p_team_id;
 delete from public.competition_ledger where team_id=p_team_id and entry_type='capital';
  delete from public.competition_inventory where team_id=p_team_id;
 delete from public.competition_suppliers where team_id=p_team_id;
 update public.competition_teams set starting_capital=160000,cash_balance=160000,production_capacity_units=4000 where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,entry_type,amount,description)
 values(v_team.competition_id,p_team_id,v_team.classroom_id,'capital',160000,'Amazon case opening capital: $160,000 main procurement budget + $30,000 emergency reserve (not released until approved)');
 insert into public.competition_suppliers(competition_id,team_id,classroom_id,supplier_code,name,lead_time_days,unit_cost,reliability_score,base_lead_time_days,base_unit_cost,base_reliability_score)
 values
 (v_team.competition_id,p_team_id,v_team.classroom_id,'SUP-A','Supplier A · China',22,12,90,12,12,90),
 (v_team.competition_id,p_team_id,v_team.classroom_id,'SUP-B','Supplier B · Germany',8,13.8,96,8,13.8,96),
 (v_team.competition_id,p_team_id,v_team.classroom_id,'SUP-C','Supplier C · USA',5,15,98,5,15,98);
 select id into v_supplier_a from public.competition_suppliers where team_id=p_team_id and supplier_code='SUP-A';
 select id into v_supplier_b from public.competition_suppliers where team_id=p_team_id and supplier_code='SUP-B';
 select id into v_supplier_c from public.competition_suppliers where team_id=p_team_id and supplier_code='SUP-C';
 insert into public.amazon_case_team_state(team_id,competition_id,classroom_id) values(p_team_id,v_team.competition_id,v_team.classroom_id);
 for v_sku in select * from public.amazon_case_skus order by sku loop
  insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
  values(v_team.competition_id,p_team_id,v_team.classroom_id,v_sku.sku,v_sku.item_name,'finished_goods',v_sku.opening_stock,
   case v_sku.sku when 'SKU-01' then 280 when 'SKU-02' then 350 when 'SKU-03' then 168 when 'SKU-04' then 112 else 70 end,0);
  insert into public.amazon_case_supplier_offers(team_id,supplier_id,supplier_code,sku,unit_price,moq,max_capacity,lead_time_days,otif_pct,defect_rate_pct) values
   (p_team_id,v_supplier_a,'SUP-A',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 12 when 'SKU-02' then 8 when 'SKU-03' then 28 when 'SKU-04' then 35 else 48 end,
    case v_sku.sku when 'SKU-03' then 50 when 'SKU-04' then 25 when 'SKU-05' then 10 else 100 end,
    case v_sku.sku when 'SKU-01' then 2500 when 'SKU-02' then 3000 when 'SKU-03' then 1400 when 'SKU-04' then 900 else 550 end,22,90,2.5),
   (p_team_id,v_supplier_b,'SUP-B',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 13.8 when 'SKU-02' then 9.2 when 'SKU-03' then 32.2 when 'SKU-04' then 40.25 else 55.2 end,
    case v_sku.sku when 'SKU-03' then 25 when 'SKU-04' then 20 when 'SKU-05' then 10 else 50 end,
    case v_sku.sku when 'SKU-01' then 700 when 'SKU-02' then 800 when 'SKU-03' then 400 when 'SKU-04' then 250 else 150 end,8,96,1),
   (p_team_id,v_supplier_c,'SUP-C',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 15 when 'SKU-02' then 10 when 'SKU-03' then 35 when 'SKU-04' then 43.75 else 60 end,
    case v_sku.sku when 'SKU-03' then 20 when 'SKU-04' then 10 when 'SKU-05' then 5 else 25 end,
    case v_sku.sku when 'SKU-01' then 500 when 'SKU-02' then 600 when 'SKU-03' then 300 when 'SKU-04' then 200 else 100 end,5,98,0.5);
  -- Seed demand as three dated waves; totals reconcile exactly to the agreed 30-day crisis demand.
  for v_order_qty in 1..3 loop
   insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
   values(v_team.competition_id,p_team_id,v_team.classroom_id,
    'AMZ-'||v_sku.sku||'-R'||v_order_qty,v_sku.sku,v_sku.item_name,
    case v_order_qty when 1 then floor(v_sku.crisis_demand*0.30)::integer
      when 2 then floor(v_sku.crisis_demand*0.35)::integer
      else v_sku.crisis_demand-floor(v_sku.crisis_demand*0.30)::integer-floor(v_sku.crisis_demand*0.35)::integer end,
    v_sku.selling_price,now()+make_interval(days=>v_order_qty*10));
  end loop;
 end loop;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,event_type,description,metadata)
 values(v_team.competition_id,p_team_id,v_team.classroom_id,'amazon_case_initialized',
  'Amazon Global Combined Crisis team data initialized',
  jsonb_build_object('horizon_days',30,'round_days',10,'demand_shock_pct',40,'supplier_a_delay_days',10,'sku_count',5,'opening_capital',160000,'emergency_reserve',30000));
 return jsonb_build_object('team_id',p_team_id,'sku_count',5,'supplier_count',3,'demand_units',9800,'opening_stock_units',1850);
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_create_role_tasks(p_competition_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    v_description:='ROLE: Procurement Manager. CASE: Amazon Global Combined Crisis (fictional educational simulation). Mission: cover 9,800 units of crisis demand across five SKUs, starting with 1,850 units of inventory, while demand is +40% and Supplier A (China) is delayed by 10 extra days (22-day crisis lead time). You control supplier allocation, PO quantities, order day, price and the $160,000 main procurement budget. A separate $30,000 reserve requires team approval. Supplier A/B/C have SKU-specific MOQ, capacity and prices shown in the live case panel; OTIF assumptions are 90/96/98% and defect rates are 2.5/1/0.5% respectively. Build a feasible SKU-by-SKU sourcing plan; compare total cost and arrival dates; ensure all needed stock arrives by Day 30. Choose Cost-focused (A >=60%) or Balanced (A 40–70%). Service-focused (B+C >=60%) is unavailable because B+C combined capacity is only 4,000 of 7,950 net required units (50.3%). Any strategy change and reserve draw require team approval. Explain your allocation, budget headroom, risk and contingency for each of the three 10-day rounds. Do not invent supplier commitments.';
   elsif v_member.operational_role='supplier' then
    v_title:='Supplier relationship and SLA recovery plan';v_priority:='high';v_due_round:=1;
    v_description:='ROLE: Supplier Relations Manager. Manage Supplier A (China, 22-day crisis lead, 90% OTIF, 2.5% defects), Supplier B (Germany, 8 days, 96% OTIF, 1% defects) and Supplier C (USA, 5 days, 98% OTIF, 0.5% defects). All case data are synthetic. Prepare a supplier scorecard; identify the impact of the 10-day A delay; define confirmation checkpoints, escalation triggers, recovery commitments, quality controls and alternative-source communication. Do not change Procurement allocation or override SKU capacity/MOQ. Submit a written supplier recovery brief with quantified service and cost consequences.';
   elsif v_member.operational_role='manufacturer' then
    v_title:='Fulfillment operations: pick, pack and backlog recovery';v_priority:='critical';v_due_round:=2;
    v_description:='ROLE: Fulfillment Operations Manager (not a manufacturer). There is no production in this case. Manage order prioritisation, pick waves, packing accuracy, release-to-transport and backlog recovery. Use only received finished-goods inventory. The live workflow limits release to available stock and 4,000 units of throughput per round. Prioritise due dates and high-risk orders; coordinate with Warehouse on availability and Transport on dispatch capacity. Submit a pick/pack wave plan, explain prioritisation rules, and quantify how many units can be safely released in each 10-day round.';
   elsif v_member.operational_role='warehouse' then
    v_title:='Warehouse control: receiving, storage and inventory accuracy';v_priority:='critical';v_due_round:=2;
    v_description:='ROLE: Warehouse Manager. Control inbound receiving, put-away, storage, inventory accuracy and pick-face availability. Opening finished-goods stock is 1,850 units across five SKUs. Receive purchase orders only at their virtual ETA; inspect supplier quality, quarantine defective units, record disposal/return, update usable stock and coordinate release reservations with Fulfillment. Provisional warehouse capacity is 8,000 units and can be tuned by the teacher. Design receiving priorities, cycle-count controls, capacity protection and exception escalation. Never receive an unavailable or unplaced PO.';
   else
    v_title:='Transport execution: dispatch, routing and OTIF';v_priority:='high';v_due_round:=3;
    v_description:='ROLE: Transport Manager. Dispatch only quantities released by Fulfillment Operations. Plan carrier capacity, dispatch sequence, lane choice and delivery confirmation. Choose Economy ($1.75/unit, 3 days, 2,500 units/round), Standard ($2.50/unit, 2 days, 2,200 units/round) or Express ($4.25/unit, 1 day, 1,000 units/round). Respect ready-to-dispatch quantities, inventory, order balance and Day 30 horizon. Prioritise due orders, track in-transit shipments, confirm delivery only after ETA, and report on-time-in-full performance, freight spend and exceptions. Submit a dispatch wave and contingency plan.';
   end if;
   insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_to,assigned_role,title,description,priority,due_at,due_round,created_by)
   values(p_competition_id,v_team.id,v_classroom,v_member.student_id,v_member.operational_role,v_title,v_description,v_priority,null,v_due_round,(select auth.uid()));
   v_count:=v_count+1;
  end loop;
 end loop;
 return v_count;
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_record_supplier_commitment(p_team_id uuid, p_supplier_code text, p_sku text, p_quantity integer, p_expected_arrival_day integer, p_status text, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_offer public.amazon_case_supplier_offers%rowtype; v_id uuid; v_min_day integer; v_existing integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,p_team_id,array['supplier']) then raise exception 'Only Supplier Relations Manager can record supplier commitments'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id for update;
 perform public.amazon_assert_round_open(v_team.competition_id);
 select * into v_offer from public.amazon_case_supplier_offers where team_id=p_team_id and supplier_code=p_supplier_code and sku=upper(p_sku);
 if not found then raise exception 'Supplier offer for this SKU was not found'; end if;
 if p_quantity is null or p_quantity<1 then raise exception 'Commitment quantity must be positive'; end if;
 select coalesce(sum(committed_quantity),0) into v_existing from public.amazon_case_supplier_commitments
 where team_id=p_team_id and supplier_code=p_supplier_code and sku=upper(p_sku);
 if v_existing+p_quantity>v_offer.max_capacity then raise exception 'Total supplier commitments exceed this SKU capacity; remaining capacity % units',greatest(0,v_offer.max_capacity-v_existing); end if;
 v_min_day:=(v_clock.current_round-1)*10+1+v_offer.lead_time_days;
 if p_expected_arrival_day is null or p_expected_arrival_day<v_min_day or p_expected_arrival_day>30 then
  raise exception 'Promised arrival must be between earliest feasible Day % and Day 30',v_min_day;
 end if;
 if p_status not in ('confirmed','at_risk','escalated') then raise exception 'Invalid commitment status'; end if;
 if char_length(trim(coalesce(p_note,'')))<8 then raise exception 'Add a short supplier communication / escalation note'; end if;
 insert into public.amazon_case_supplier_commitments(competition_id,team_id,supplier_code,sku,committed_quantity,expected_arrival_day,commitment_status,note,created_by)
 values(v_team.competition_id,p_team_id,p_supplier_code,upper(p_sku),p_quantity,p_expected_arrival_day,p_status,trim(p_note),(select auth.uid()))
 returning id into v_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,p_team_id,v_team.classroom_id,(select auth.uid()),'supplier','amazon_supplier_commitment',
  'Supplier commitment recorded',jsonb_build_object('commitment_id',v_id,'supplier',p_supplier_code,'sku',p_sku,'quantity',p_quantity,'arrival_day',p_expected_arrival_day,'status',p_status));
 return v_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_submit_approval(p_team_id uuid, p_approval_type text, p_reason text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 perform public.amazon_assert_round_open(v_team.competition_id);
 if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 if p_approval_type not in ('reserve_draw','strategy_change','cross_functional') then raise exception 'Invalid approval type'; end if;
 if p_approval_type in ('reserve_draw','strategy_change') and not public.is_competition_role(v_team.competition_id,p_team_id,array['procurement']) then
  raise exception 'Only Procurement Manager can submit this request'; end if;
 if char_length(trim(coalesce(p_reason,'')))<10 then raise exception 'Explain the reason (at least 10 characters)'; end if;
 if p_approval_type='reserve_draw' and (coalesce((p_payload->>'amount')::numeric,0)<=0 or (p_payload->>'amount')::numeric>30000) then raise exception 'Reserve request must be between $1 and $30,000'; end if;
 if p_approval_type='strategy_change' and coalesce(p_payload->>'posture','') not in ('cost_focused','balanced','service_focused') then raise exception 'Invalid target procurement posture'; end if;
 if p_approval_type='strategy_change' and p_payload->>'posture'='service_focused' then
  raise exception 'Service-focused posture is infeasible: Suppliers B+C can cover at most 4,000 of 7,950 net required units (50.3%%), below the 60%% limit';
 end if;
 insert into public.amazon_case_approvals(competition_id,team_id,requested_by,approval_type,reason,payload)
 values(v_team.competition_id,p_team_id,(select auth.uid()),p_approval_type,trim(p_reason),
  case when p_approval_type='strategy_change' then
   coalesce(p_payload,'{}'::jsonb)||jsonb_build_object('previous_posture',
    (select strategic_posture from public.amazon_case_team_state where team_id=p_team_id),
    'affected_roles',jsonb_build_array('supplier','warehouse','manufacturer','transport'))
   when p_approval_type='reserve_draw' then
   coalesce(p_payload,'{}'::jsonb)||jsonb_build_object('affected_roles',jsonb_build_array('warehouse','manufacturer','transport'))
   else coalesce(p_payload,'{}'::jsonb) end) returning id into v_id;
 return v_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.amazon_dispose_defects(p_quality_receipt_id uuid, p_quantity integer, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_receipt public.amazon_case_quality_receipts%rowtype; v_remaining integer; v_new integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_receipt from public.amazon_case_quality_receipts where id=p_quality_receipt_id for update;
 if not found then raise exception 'Quality receipt not found'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_receipt.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 perform public.amazon_assert_round_open(v_receipt.competition_id);
 if not public.is_competition_role(v_receipt.competition_id,v_receipt.team_id,array['warehouse']) then raise exception 'Only Warehouse Manager can clear quarantine stock'; end if;
 v_remaining:=v_receipt.defective_quantity-v_receipt.disposed_quantity;
 if p_quantity is null or p_quantity<1 or p_quantity>v_remaining then raise exception 'Disposal quantity exceeds remaining quarantine stock'; end if;
 if char_length(trim(coalesce(p_reason,'')))<8 then raise exception 'Record a reason for disposal or supplier return'; end if;
 v_new:=v_receipt.disposed_quantity+p_quantity;
 update public.amazon_case_quality_receipts set disposed_quantity=v_new where id=p_quality_receipt_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select c.id,v_receipt.team_id,t.classroom_id,(select auth.uid()),'warehouse','amazon_quality_disposed',
  'Defective units removed from quarantine',jsonb_build_object('quality_receipt_id',p_quality_receipt_id,'quantity',p_quantity,'reason',trim(p_reason))
 from public.competitions c join public.competition_teams t on t.id=v_receipt.team_id where c.id=v_receipt.competition_id;
 return jsonb_build_object('disposed_quantity',v_new,'remaining_quarantine',v_receipt.defective_quantity-v_new);
end; $function$;

CREATE OR REPLACE FUNCTION public.set_competition_status(p_competition_id uuid, p_status text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_current text; v_paused_at timestamptz; v_team_count integer; v_member_count integer; v_class_member_count integer; v_min_team_size integer; v_max_team_size integer; v_round integer; v_round_limit integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_current from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can control this competition'; end if;
 if p_status not in ('active','paused','completed') then raise exception 'Invalid competition status'; end if;
 if p_status='active' and v_current='draft' then
  select count(*) into v_team_count from public.competition_teams where competition_id=p_competition_id;
  select count(*) into v_member_count from public.competition_team_members where competition_id=p_competition_id;
  if v_team_count not between 2 and 4 then raise exception 'Create between two and four teams before starting'; end if;
  select count(*) into v_class_member_count from public.classroom_members where classroom_id=v_classroom_id;
  if v_member_count<>v_class_member_count then raise exception 'Assign every classroom student to exactly one competition team'; end if;
  select min(member_count),max(member_count) into v_min_team_size,v_max_team_size
   from (select t.id,count(m.id)::integer as member_count from public.competition_teams t
    left join public.competition_team_members m on m.team_id=t.id and m.competition_id=t.competition_id
    where t.competition_id=p_competition_id group by t.id) sizes;
  if coalesce(v_min_team_size,0)=0 or coalesce(v_max_team_size,0)-coalesce(v_min_team_size,0)>1 then
   raise exception 'Balance team sizes so every team differs by no more than one student';
  end if;
  if exists(
   select 1 from public.competition_teams t
   where t.competition_id=p_competition_id and (
    not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='procurement')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='supplier')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='manufacturer')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='warehouse')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='transport')
   )
  ) then
   raise exception 'Every team needs Procurement, Supplier, Manufacturer, Warehouse and Transport roles (at least five students per team) before starting';
  end if;
 end if;
 if v_current='completed' then raise exception 'Completed competitions cannot be reopened'; end if;
 if v_current='draft' and p_status not in ('active') then raise exception 'A draft competition can only be started'; end if;
 if v_current='active' and p_status='paused' and exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='amazon-global-combined-crisis') then
  update public.competitions set status='paused',paused_at=now() where id=p_competition_id;
  return p_status;
 end if;
 if v_current='paused' and p_status='active' and exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='amazon-global-combined-crisis') then
  select paused_at into v_paused_at from public.competitions where id=p_competition_id;
  update public.competition_rounds set ends_at=ends_at+(now()-coalesce(v_paused_at,now()))
   where competition_id=p_competition_id and round_number=(select current_round from public.competition_simulation_clock where competition_id=p_competition_id) and status='active';
  update public.competitions set status='active',paused_at=null where id=p_competition_id;
  return p_status;
 end if;
 if p_status='completed' then
  select current_round,round_limit into v_round,v_round_limit from public.competition_simulation_clock where competition_id=p_competition_id for update;
  if v_round is null then raise exception 'Simulation clock is not initialized'; end if;
  if v_round<v_round_limit then raise exception 'Complete all simulation rounds before finalising the competition'; end if;
  if exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='amazon-global-combined-crisis') then
   if exists(select 1 from public.competition_rounds where competition_id=p_competition_id and round_number=v_round and status='active' and ends_at>now()) then
    raise exception 'Final round timer must expire before the case can be completed';
   end if;
   if exists(select 1 from public.competition_shipments where competition_id=p_competition_id and status in ('in_transit','delayed')) then
    raise exception 'Resolve or explicitly cancel all in-transit shipments before finalising';
   end if;
   update public.competition_rounds set status='completed' where competition_id=p_competition_id and round_number=v_round;
   update public.amazon_case_approvals set status='expired',resolved_at=now() where competition_id=p_competition_id and status='pending';
  end if;
  if exists(select 1 from public.competition_decisions where competition_id=p_competition_id and score is null) then
   raise exception 'Evaluate all submitted student decisions before finalising the competition';
  end if;
  if not exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then
   raise exception 'Generate the advanced role case pack before finalising the competition';
  end if;
  if exists(
   select 1 from public.competition_teams t
   where t.competition_id=p_competition_id and (
    not exists(select 1 from public.competition_tasks x where x.competition_id=p_competition_id and x.team_id=t.id and x.assigned_role='procurement')
    or not exists(select 1 from public.competition_tasks x where x.competition_id=p_competition_id and x.team_id=t.id and x.assigned_role='supplier')
    or not exists(select 1 from public.competition_tasks x where x.competition_id=p_competition_id and x.team_id=t.id and x.assigned_role='manufacturer')
    or not exists(select 1 from public.competition_tasks x where x.competition_id=p_competition_id and x.team_id=t.id and x.assigned_role='warehouse')
    or not exists(select 1 from public.competition_tasks x where x.competition_id=p_competition_id and x.team_id=t.id and x.assigned_role='transport')
   )
  ) then
   raise exception 'Every team must have all five role case tasks before finalising the competition';
  end if;
  if exists(
   select 1 from public.competition_team_members m
   where m.competition_id=p_competition_id
     and not exists(
      select 1 from public.competition_tasks x
      where x.competition_id=m.competition_id and x.team_id=m.team_id
        and x.assigned_to=m.student_id and x.assigned_role=m.operational_role
     )
  ) then
   raise exception 'Every student must receive an individually assigned role case task';
  end if;
  if exists(
   select 1 from public.competition_team_members m
   where m.competition_id=p_competition_id
     and not exists(
      select 1 from public.competition_decisions d
      where d.competition_id=m.competition_id and d.team_id=m.team_id
        and d.student_id=m.student_id and d.score is not null
     )
  ) then
   raise exception 'Every student must submit at least one evaluated operational decision';
  end if;
  if exists(select 1 from public.competition_tasks where competition_id=p_competition_id and (status<>'approved' or score is null)) then
   raise exception 'Grade every role case task before finalising the competition';
  end if;
  perform public.calculate_competition_scores(p_competition_id,v_round);
  insert into public.competition_score_snapshots(competition_id,team_id,round_number,metrics,component_scores,total_score)
  select p_competition_id,m.team_id,v_round,
   jsonb_build_object('orders',m.total_orders,'delivered_orders',m.delivered_orders,'delivered_units',m.delivered_units,
    'on_time_units',m.on_time_units,'due_units',m.due_units,'average_delivery_days',m.avg_delivery_days,
    'inventory_units',m.inventory_units,'low_stock_skus',m.low_stock_skus,'produced_units',m.produced_units,
    'production_runs',m.production_runs,'revenue',m.revenue,'operating_cost',m.operating_cost,
    'evaluated_decisions',m.evaluated_decisions,'coverage_pct',m.score_coverage_pct,
    'zero_score_due_to_insufficient_evidence',m.total_score is null),
   m.component_scores,coalesce(m.total_score,0)
  from public.competition_team_live_metrics m where m.competition_id=p_competition_id
  on conflict(competition_id,team_id,round_number) do update set metrics=excluded.metrics,
   component_scores=excluded.component_scores,total_score=excluded.total_score,calculated_at=now();
 end if;
 update public.competitions set status=p_status,
  starts_at=case when p_status='active' and starts_at is null then now() else starts_at end,
  completed_at=case when p_status='completed' then now() else completed_at end
 where id=p_competition_id;
 return p_status;
end;
$function$;
