-- Current authoritative function snapshot; apply after the base competition RPCs.
CREATE OR REPLACE FUNCTION public.competition_dispatch_shipment(p_order_id uuid, p_quantity integer, p_origin text, p_destination text, p_carrier text, p_transport_cost numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_order public.competition_customer_orders%rowtype;
 v_profile jsonb; v_transport_rate numeric; v_min_transport numeric; v_max_transport numeric; v_transit_days integer;
 v_stock integer; v_shipped integer; v_id uuid; v_cash numeric; v_final_virtual timestamptz; v_eta timestamptz;
 v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not exists(select 1 from public.competitions where id=v_order.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can dispatch shipments'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 if v_order.status in('cancelled','delivered') then raise exception 'This customer order cannot be shipped'; end if;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then raise exception 'Invalid shipment details'; end if;
 select ct.operating_profile into v_profile from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id where t.id=v_order.team_id;
 v_transport_rate:=coalesce((v_profile->>'transport_cost_per_unit')::numeric,0);
 if v_transport_rate<=0 then raise exception 'Company transport benchmark is not configured'; end if;
 v_min_transport:=round(p_quantity*v_transport_rate*0.8,2);
 v_max_transport:=round(p_quantity*v_transport_rate*1.5,2);
 if p_transport_cost is null or p_transport_cost not between v_min_transport and v_max_transport then
  raise exception 'Transport cost must be within %–% for this shipment',v_min_transport,v_max_transport;
 end if;
 if p_transport_cost<=p_quantity*v_transport_rate*0.9 then v_transit_days:=3;
 elsif p_transport_cost>=p_quantity*v_transport_rate*1.25 then v_transit_days:=1;
 else v_transit_days:=2; end if;
 v_final_virtual:=v_clock.virtual_now+make_interval(days=>greatest(0,v_clock.round_limit-v_clock.current_round)*7);
 v_eta:=v_clock.virtual_now+make_interval(days=>v_transit_days);
 if v_eta>v_final_virtual then raise exception 'Shipment ETA would fall after competition close (%)',v_final_virtual; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 if v_shipped+p_quantity>v_order.quantity then raise exception 'Shipment quantity exceeds the outstanding customer order'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 select cash_balance into v_cash from public.competition_teams where id=v_order.team_id for update;
 if v_cash<p_transport_cost then raise exception 'Insufficient company cash for transport'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta,dispatched_at)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,trim(p_origin),trim(p_destination),trim(p_carrier),p_transport_cost,
  v_eta,v_clock.virtual_now)
 returning id into v_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-p_transport_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-p_transport_cost,'Shipment transport cost',v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','shipment_dispatched','Dispatched '||p_quantity||' units to '||p_destination,
 jsonb_build_object('shipment_id',v_id,'order_id',p_order_id,'stock_after',v_stock-p_quantity,'transport_cost',p_transport_cost,
 'transport_benchmark_per_unit',v_transport_rate,'transit_days',v_transit_days,'eta',v_eta));
 return v_id;
end; $function$
;
