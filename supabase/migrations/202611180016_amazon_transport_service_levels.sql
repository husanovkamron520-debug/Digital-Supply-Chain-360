
create table if not exists public.amazon_case_transport_dispatches (
 shipment_id uuid primary key references public.competition_shipments(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 service_level text not null check (service_level in ('economy','standard','express')),
 round_number integer not null,
 quantity integer not null,
 unit_cost numeric(10,2) not null,
 transit_days integer not null,
 created_at timestamptz not null default now()
);
alter table public.amazon_case_transport_dispatches enable row level security;

create or replace function public.amazon_dispatch_shipment_v2(
 p_order_id uuid,p_quantity integer,p_carrier text default 'Regional carrier',p_service_level text default 'standard'
) returns uuid language plpgsql security definer set search_path=''
as $$
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
 v_horizon:=v_clock.virtual_now+make_interval(days=>(3-v_clock.current_round)*10+9);
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
end; $$;

create or replace function public.amazon_dispatch_shipment(p_order_id uuid,p_quantity integer,p_carrier text default 'Regional carrier')
returns uuid language plpgsql security definer set search_path=''
as $$
begin
 return public.amazon_dispatch_shipment_v2(p_order_id,p_quantity,p_carrier,'standard');
end; $$;

grant execute on function public.amazon_dispatch_shipment_v2(uuid,integer,text,text) to authenticated;
