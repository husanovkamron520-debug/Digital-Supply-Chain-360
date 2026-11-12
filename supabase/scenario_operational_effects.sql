-- SupplyChain14: isolated operational effects for scenario simulations.
-- Applying this migration is safe to repeat; functions are replaced in place.
-- This file contains the full current definitions for launch_supply_scenario
-- and submit_scenario_decision. It is applied to the connected Supabase project.

create or replace function public.launch_supply_scenario(p_classroom_id uuid,p_scenario_type text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_title text; v_config jsonb; v_order_id uuid; v_order_number text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then raise exception 'Only the classroom teacher can launch scenarios'; end if;
 case p_scenario_type
 when 'supplier_delay' then
  v_title:='Supplier delay — production at risk';
  v_config:=jsonb_build_object('type','supplier_delay','severity','high','description','Your main supplier reports a 48-hour delay. Production has only two days of safety stock remaining.','impact','Potential production stoppage and late customer orders.','actions',jsonb_build_array(jsonb_build_object('key','expedite','label','Expedite an alternate supplier'),jsonb_build_object('key','allocate','label','Allocate remaining stock to priority orders'),jsonb_build_object('key','wait','label','Wait for the original supplier')));
 when 'demand_spike' then
  v_title:='Demand spike — capacity under pressure';
  v_config:=jsonb_build_object('type','demand_spike','severity','high','description','Customer demand rises by 35% for the next week, while current production capacity is already 90% utilised.','impact','Overtime cost, service failures, and inventory depletion are possible.','actions',jsonb_build_array(jsonb_build_object('key','prioritise','label','Prioritise orders by service commitment'),jsonb_build_object('key','overtime','label','Add a controlled temporary shift'),jsonb_build_object('key','promise_all','label','Promise every order immediately')));
 when 'route_disruption' then
  v_title:='Transport disruption — route unavailable';
  v_config:=jsonb_build_object('type','route_disruption','severity','critical','description','A key transport corridor is closed for 24 hours. Three customer shipments are waiting at the dispatch hub.','impact','Delivery delays and rising transport costs threaten customer service.','actions',jsonb_build_array(jsonb_build_object('key','reroute','label','Evaluate and dispatch via an alternate route'),jsonb_build_object('key','notify','label','Notify customers and revise delivery promises'),jsonb_build_object('key','dispatch_closed','label','Dispatch through the closed corridor')));
 else raise exception 'Unsupported scenario type'; end case;
 insert into public.scenarios(classroom_id,created_by,title,status,configuration,started_at)
 values(p_classroom_id,(select auth.uid()),v_title,'active',v_config,now()) returning id into v_id;
 v_order_number:='SIM-'||upper(left(replace(v_id::text,'-',''),10));
 if p_scenario_type='supplier_delay' then
  insert into public.inventory(classroom_id,scenario_id,sku,item_name,quantity,reorder_level) values(p_classroom_id,v_id,'SIM-RAW-001','Critical raw material',20,40);
  insert into public.orders(classroom_id,scenario_id,created_by,order_number,product_name,quantity,status,due_at)
  values(p_classroom_id,v_id,(select auth.uid()),v_order_number,'Customer production order',100,'delayed',now()+interval '3 days') returning id into v_order_id;
 elsif p_scenario_type='demand_spike' then
  insert into public.inventory(classroom_id,scenario_id,sku,item_name,quantity,reorder_level) values(p_classroom_id,v_id,'SIM-FG-001','Finished goods inventory',80,50);
  insert into public.orders(classroom_id,scenario_id,created_by,order_number,product_name,quantity,status,due_at)
  values(p_classroom_id,v_id,(select auth.uid()),v_order_number,'Demand surge customer order',135,'created',now()+interval '2 days') returning id into v_order_id;
 else
  insert into public.orders(classroom_id,scenario_id,created_by,order_number,product_name,quantity,status,due_at)
  values(p_classroom_id,v_id,(select auth.uid()),v_order_number,'Disrupted customer deliveries',3,'delayed',now()+interval '1 day') returning id into v_order_id;
  insert into public.shipments(classroom_id,scenario_id,order_id,created_by,origin,destination,carrier,status,eta)
  select p_classroom_id,v_id,v_order_id,(select auth.uid()),'Regional dispatch hub',
   case n when 1 then 'North distribution centre' when 2 then 'Central retail hub' else 'South customer depot' end,
   'Demo carrier','delayed',now()+interval '24 hours' from generate_series(1,3) n;
 end if;
 insert into public.activity_logs(classroom_id,scenario_id,actor_id,event_type,description,metadata)
 values(p_classroom_id,v_id,(select auth.uid()),'scenario_launched',v_title,
 jsonb_build_object('scenario_type',p_scenario_type,'simulated_order_id',v_order_id,'isolated_simulation',true));
 return v_id;
end; $$;

create or replace function public.submit_scenario_decision(p_scenario_id uuid,p_action_key text,p_rationale text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_scenario public.scenarios%rowtype; v_action jsonb; v_score integer; v_feedback text;
 v_uid uuid:=(select auth.uid()); v_stock integer; v_order_status text; v_shipment_count integer:=0;
begin
 if v_uid is null then raise exception 'Sign in is required'; end if;
 select * into v_scenario from public.scenarios where id=p_scenario_id for update;
 if not found then raise exception 'Scenario not found'; end if;
 if v_scenario.status<>'active' then raise exception 'This scenario is no longer accepting decisions'; end if;
 if not public.is_class_member(v_scenario.classroom_id) then raise exception 'You are not a member of this classroom'; end if;
 if public.is_class_teacher(v_scenario.classroom_id) then raise exception 'Teachers launch scenarios; students submit decisions'; end if;
 if exists(select 1 from public.scenario_decisions where scenario_id=p_scenario_id and student_id=v_uid) then raise exception 'You have already submitted a decision for this scenario'; end if;
 if char_length(coalesce(p_rationale,''))>1000 then raise exception 'Rationale is too long'; end if;
 select a into v_action from jsonb_array_elements(v_scenario.configuration->'actions') a where a->>'key'=p_action_key limit 1;
 if v_action is null then raise exception 'Invalid action for this scenario'; end if;
 case v_scenario.configuration->>'type'
 when 'supplier_delay' then
  v_score:=case p_action_key when 'expedite' then 95 when 'allocate' then 82 when 'wait' then 25 else 0 end;
  v_feedback:=case p_action_key when 'expedite' then 'Strong response: activate a qualified alternate source to protect continuity.' when 'allocate' then 'Good response: prioritisation protects the most important customers while supply is constrained.' else 'High-risk response: waiting leaves production exposed to a stockout.' end;
  if p_action_key='expedite' then
   update public.inventory set quantity=quantity+50,updated_at=now() where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.orders set status='approved' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  elsif p_action_key='allocate' then
   update public.inventory set quantity=greatest(quantity-10,0),updated_at=now() where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.orders set status='in_production' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  else update public.orders set status='delayed' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  end if;
 when 'demand_spike' then
  v_score:=case p_action_key when 'prioritise' then 95 when 'overtime' then 84 when 'promise_all' then 20 else 0 end;
  v_feedback:=case p_action_key when 'prioritise' then 'Strong response: protect service commitments and make capacity trade-offs explicit.' when 'overtime' then 'Good response: additional capacity helps, but cost and fatigue need monitoring.' else 'Risky response: promising beyond capacity creates avoidable service failures.' end;
  if p_action_key='prioritise' then update public.orders set status='approved' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  elsif p_action_key='overtime' then
   update public.orders set status='in_production' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.inventory set quantity=greatest(quantity-20,0),updated_at=now() where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  else update public.orders set status='delayed' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  end if;
 when 'route_disruption' then
  v_score:=case p_action_key when 'reroute' then 95 when 'notify' then 80 when 'dispatch_closed' then 5 else 0 end;
  v_feedback:=case p_action_key when 'reroute' then 'Strong response: restore flow while checking cost, capacity, and safety.' when 'notify' then 'Responsible response: transparent communication limits customer impact, though freight remains delayed.' else 'Unsafe response: never send shipments through a closed or prohibited route.' end;
  if p_action_key='reroute' then
   update public.shipments set status='in_transit',eta=now()+interval '18 hours' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.orders set status='in_transit' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  elsif p_action_key='notify' then
   update public.shipments set status='delayed',eta=now()+interval '24 hours' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.orders set status='delayed' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  else
   update public.shipments set status='delayed',eta=now()+interval '48 hours' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
   update public.orders set status='delayed' where scenario_id=p_scenario_id and classroom_id=v_scenario.classroom_id;
  end if;
 else raise exception 'Unsupported scenario type'; end case;
 insert into public.scenario_decisions(scenario_id,classroom_id,student_id,selected_action,rationale,score,feedback)
 values(p_scenario_id,v_scenario.classroom_id,v_uid,p_action_key,coalesce(p_rationale,''),v_score,v_feedback);
 select coalesce(sum(quantity),0) into v_stock from public.inventory where scenario_id=p_scenario_id;
 select status into v_order_status from public.orders where scenario_id=p_scenario_id limit 1;
 select count(*) into v_shipment_count from public.shipments where scenario_id=p_scenario_id;
 insert into public.activity_logs(classroom_id,scenario_id,actor_id,event_type,description,metadata)
 values(v_scenario.classroom_id,p_scenario_id,v_uid,'scenario_decision_submitted','A student submitted a scenario decision',
 jsonb_build_object('score',v_score,'action',p_action_key,'simulated_stock_units',v_stock,'simulated_order_status',v_order_status,'simulated_shipments',v_shipment_count));
 return jsonb_build_object('score',v_score,'feedback',v_feedback,'submitted',true,
 'simulation',jsonb_build_object('stock_units',v_stock,'order_status',v_order_status,'shipment_count',v_shipment_count));
end; $$;
