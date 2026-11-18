
create table if not exists public.amazon_case_fulfillment (
 order_id uuid primary key references public.competition_customer_orders(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 ready_quantity integer not null default 0,
 updated_round integer not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.amazon_case_fulfillment enable row level security;

create or replace function public.amazon_fulfill_order(p_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_order public.competition_customer_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_stock integer; v_ready integer; v_shipped integer; v_round_total integer; v_cap integer; v_comp_status text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['manufacturer']) then
  raise exception 'Only Fulfillment Operations Manager can release an order for fulfilment'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id for update;
 select status into v_comp_status from public.competitions where id=v_order.competition_id;
 if v_comp_status<>'active' or v_clock.current_round>3 then raise exception 'Amazon case is not accepting fulfilment actions'; end if;
 if p_quantity is null or p_quantity<1 then raise exception 'Quantity must be positive'; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 select coalesce(ready_quantity,0) into v_ready from public.amazon_case_fulfillment where order_id=p_order_id;
 if v_shipped+v_ready+p_quantity>v_order.quantity then raise exception 'Fulfilment quantity exceeds the outstanding order quantity'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock < (select coalesce(sum(ready_quantity),0) from public.amazon_case_fulfillment where team_id=v_order.team_id)+p_quantity then
  raise exception 'Insufficient unallocated finished-goods inventory'; end if;
 select production_capacity_units into v_cap from public.competition_teams where id=v_order.team_id;
 select coalesce(sum(f.ready_quantity),0) into v_round_total from public.amazon_case_fulfillment f
 where f.team_id=v_order.team_id and f.updated_round=v_clock.current_round;
 if v_round_total+p_quantity>v_cap then raise exception 'Fulfilment throughput capacity exceeded for this round'; end if;
 insert into public.amazon_case_fulfillment(order_id,team_id,ready_quantity,updated_round)
 values(p_order_id,v_order.team_id,p_quantity,v_clock.current_round)
 on conflict(order_id) do update set ready_quantity=amazon_case_fulfillment.ready_quantity+excluded.ready_quantity,
 updated_round=excluded.updated_round,updated_at=now();
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'manufacturer','amazon_fulfilment_ready',
 'Order prepared for fulfilment',jsonb_build_object('order_id',p_order_id,'quantity',p_quantity,'round',v_clock.current_round));
 return jsonb_build_object('order_id',p_order_id,'ready_quantity',v_ready+p_quantity,'remaining_stock',v_stock-(select coalesce(sum(ready_quantity),0) from public.amazon_case_fulfillment where team_id=v_order.team_id));
end; $$;

create or replace function public.amazon_dispatch_shipment(p_order_id uuid,p_quantity integer,p_carrier text default 'Regional carrier')
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_order public.competition_customer_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_ready integer; v_stock integer; v_cost numeric; v_eta timestamptz; v_id uuid; v_cash numeric; v_horizon timestamptz;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only Transport Manager can dispatch'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id for update;
 if not exists(select 1 from public.competitions where id=v_order.competition_id and status='active') then raise exception 'Amazon case is not active'; end if;
 select coalesce(ready_quantity,0) into v_ready from public.amazon_case_fulfillment where order_id=p_order_id for update;
 if p_quantity is null or p_quantity<1 or p_quantity>v_ready then raise exception 'Dispatch quantity exceeds packed and released quantity'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 v_cost:=p_quantity*2.5;
 select cash_balance into v_cash from public.competition_teams where id=v_order.team_id for update;
 if v_cash<v_cost then raise exception 'Insufficient cash for outbound transport'; end if;
 v_eta:=v_clock.virtual_now+interval '2 days';
 v_horizon:=v_clock.virtual_now+make_interval(days=>(3-v_clock.current_round)*10+10);
 if v_eta>v_horizon then raise exception 'Shipment ETA falls outside the 30-day horizon'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta,dispatched_at)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,'Fulfilment centre','Customer destination',
  coalesce(nullif(trim(p_carrier),''),'Regional carrier'),v_cost,v_eta,v_clock.virtual_now) returning id into v_id;
 update public.amazon_case_fulfillment set ready_quantity=ready_quantity-p_quantity,updated_at=now() where order_id=p_order_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-v_cost,'Amazon outbound delivery cost',v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','amazon_shipment_dispatched',
 'Amazon customer shipment dispatched',jsonb_build_object('shipment_id',v_id,'quantity',p_quantity,'cost',v_cost,'eta',v_eta));
 return v_id;
end; $$;

create or replace function public.amazon_submit_approval(p_team_id uuid,p_approval_type text,p_reason text,p_payload jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if p_approval_type not in ('reserve_draw','strategy_change','cross_functional') then raise exception 'Invalid approval type'; end if;
 if p_approval_type in ('reserve_draw','strategy_change') and not public.is_competition_role(v_team.competition_id,p_team_id,array['procurement']) then
  raise exception 'Only Procurement Manager can submit this request'; end if;
 if char_length(trim(coalesce(p_reason,'')))<10 then raise exception 'Explain the reason (at least 10 characters)'; end if;
 if p_approval_type='reserve_draw' and (coalesce((p_payload->>'amount')::numeric,0)<=0 or (p_payload->>'amount')::numeric>30000) then raise exception 'Reserve request must be between $1 and $30,000'; end if;
 if p_approval_type='strategy_change' and coalesce(p_payload->>'posture','') not in ('cost_focused','balanced','service_focused') then raise exception 'Invalid target procurement posture'; end if;
 insert into public.amazon_case_approvals(competition_id,team_id,requested_by,approval_type,reason,payload)
 values(v_team.competition_id,p_team_id,(select auth.uid()),p_approval_type,trim(p_reason),coalesce(p_payload,'{}'::jsonb)) returning id into v_id;
 return v_id;
end; $$;

create or replace function public.amazon_vote_approval(p_approval_id uuid,p_vote text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_a public.amazon_case_approvals%rowtype; v_member public.competition_team_members%rowtype;
 v_yes integer; v_no integer; v_required jsonb; v_missing integer; v_state public.amazon_case_team_state%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_vote not in ('approve','reject') then raise exception 'Vote must be approve or reject'; end if;
 select * into v_a from public.amazon_case_approvals where id=p_approval_id for update;
 if not found or v_a.status<>'pending' then raise exception 'Pending approval not found'; end if;
 if v_a.requested_by=(select auth.uid()) then raise exception 'Requester cannot approve their own request'; end if;
 select * into v_member from public.competition_team_members where team_id=v_a.team_id and student_id=(select auth.uid());
 if not found then raise exception 'Only team members can vote'; end if;
 insert into public.amazon_case_approval_votes(approval_id,student_id,vote) values(p_approval_id,(select auth.uid()),p_vote)
 on conflict(approval_id,student_id) do update set vote=excluded.vote,created_at=now();
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
  elsif v_a.approval_type='strategy_change' then
   update public.amazon_case_team_state set strategic_posture=v_a.payload->>'posture' where team_id=v_a.team_id;
  end if;
 end if;
 return jsonb_build_object('status',(select status from public.amazon_case_approvals where id=p_approval_id),'approve_votes',v_yes,'reject_votes',v_no,'affected_roles_pending',v_missing);
end; $$;

grant execute on function public.amazon_fulfill_order(uuid,integer) to authenticated;
grant execute on function public.amazon_dispatch_shipment(uuid,integer,text) to authenticated;
grant execute on function public.amazon_submit_approval(uuid,text,text,jsonb) to authenticated;
grant execute on function public.amazon_vote_approval(uuid,text) to authenticated;
