
-- Amazon Global Combined Crisis: isolated case engine. Existing competitions remain unchanged.
insert into public.company_templates
(slug,name,industry,business_model,operating_profile,scoring_weights,case_study_note,source_urls,active)
values
('amazon-global-combined-crisis','Amazon Global Combined Crisis','E-commerce and global fulfilment',
 'Global e-commerce fulfilment network facing a 40% demand shock and a 10-day disruption at its primary China supplier.',
 '{"product_name":"Amazon simulated assortment","selling_price":30,"baseline_lead_time_days":8,"capacity_units_per_round":1500,"transport_cost_per_unit":2.5,"initial_raw_units":0,"initial_finished_units":0,"raw_material_unit_cost":0,"conversion_cost_per_unit":0,"amazon_case":true}'::jsonb,
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb,
 'Fictional educational simulation inspired by e-commerce fulfilment. All suppliers, prices, quantities, capacities and events are synthetic and are not official Amazon data.',
 '[]'::jsonb,true)
on conflict (slug) do update set
 name=excluded.name,industry=excluded.industry,business_model=excluded.business_model,
 operating_profile=excluded.operating_profile,scoring_weights=excluded.scoring_weights,
 case_study_note=excluded.case_study_note,active=true;

create table if not exists public.amazon_case_team_state (
 team_id uuid primary key references public.competition_teams(id) on delete cascade,
 competition_id uuid not null references public.competitions(id) on delete cascade,
 classroom_id uuid not null,
 main_budget numeric(14,2) not null default 160000,
 reserve_budget numeric(14,2) not null default 30000,
 reserve_approved numeric(14,2) not null default 0,
 committed_spend numeric(14,2) not null default 0,
 strategic_posture text not null default 'balanced' check (strategic_posture in ('cost_focused','balanced','service_focused')),
 warehouse_capacity_units integer not null default 8000,
 created_at timestamptz not null default now()
);
create table if not exists public.amazon_case_skus (
 sku text primary key,
 item_name text not null,
 normal_demand integer not null,
 crisis_demand integer not null,
 opening_stock integer not null,
 selling_price numeric(12,2) not null
);
insert into public.amazon_case_skus values
 ('SKU-01','Wireless Earbuds',2000,2800,500,30),
 ('SKU-02','Wireless Mouse',2500,3500,700,20),
 ('SKU-03','Smart Watch',1200,1680,300,70),
 ('SKU-04','Coffee Maker',800,1120,200,90),
 ('SKU-05','Ergonomic Office Chair',500,700,150,120)
on conflict (sku) do update set item_name=excluded.item_name,normal_demand=excluded.normal_demand,
 crisis_demand=excluded.crisis_demand,opening_stock=excluded.opening_stock,selling_price=excluded.selling_price;

create table if not exists public.amazon_case_supplier_offers (
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 supplier_id uuid not null references public.competition_suppliers(id) on delete cascade,
 supplier_code text not null check (supplier_code in ('SUP-A','SUP-B','SUP-C')),
 sku text not null references public.amazon_case_skus(sku),
 unit_price numeric(12,2) not null,
 moq integer not null,
 max_capacity integer not null,
 lead_time_days integer not null,
 primary key(team_id,supplier_code,sku)
);
create table if not exists public.amazon_case_approvals (
 id uuid primary key default gen_random_uuid(),
 competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 requested_by uuid not null,
 approval_type text not null check (approval_type in ('reserve_draw','strategy_change','cross_functional')),
 reason text not null,
 payload jsonb not null default '{}'::jsonb,
 status text not null default 'pending' check (status in ('pending','approved','rejected','expired')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);
create table if not exists public.amazon_case_approval_votes (
 approval_id uuid not null references public.amazon_case_approvals(id) on delete cascade,
 student_id uuid not null,
 vote text not null check (vote in ('approve','reject')),
 created_at timestamptz not null default now(),
 primary key(approval_id,student_id)
);
alter table public.amazon_case_team_state enable row level security;
alter table public.amazon_case_supplier_offers enable row level security;
alter table public.amazon_case_approvals enable row level security;
alter table public.amazon_case_approval_votes enable row level security;

create or replace function public.amazon_initialize_team(p_team_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
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
 delete from public.competition_inventory where team_id=p_team_id;
 delete from public.competition_suppliers where team_id=p_team_id;
 update public.competition_teams set starting_capital=190000,cash_balance=190000,production_capacity_units=1500 where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,entry_type,amount,description)
 values(v_team.competition_id,p_team_id,v_team.classroom_id,'capital',190000,'Amazon case opening capital: $160,000 main procurement budget + $30,000 emergency reserve');
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
  values(v_team.competition_id,p_team_id,v_team.classroom_id,v_sku.sku,v_sku.item_name,'finished_goods',v_sku.opening_stock,0,0);
  insert into public.amazon_case_supplier_offers(team_id,supplier_id,supplier_code,sku,unit_price,moq,max_capacity,lead_time_days) values
   (p_team_id,v_supplier_a,'SUP-A',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 12 when 'SKU-02' then 8 when 'SKU-03' then 28 when 'SKU-04' then 35 else 48 end,
    case v_sku.sku when 'SKU-03' then 50 when 'SKU-04' then 25 when 'SKU-05' then 10 else 100 end,
    case v_sku.sku when 'SKU-01' then 2500 when 'SKU-02' then 3000 when 'SKU-03' then 1400 when 'SKU-04' then 900 else 550 end,22),
   (p_team_id,v_supplier_b,'SUP-B',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 13.8 when 'SKU-02' then 9.2 when 'SKU-03' then 32.2 when 'SKU-04' then 40.25 else 55.2 end,
    case v_sku.sku when 'SKU-03' then 25 when 'SKU-04' then 20 when 'SKU-05' then 10 else 50 end,
    case v_sku.sku when 'SKU-01' then 700 when 'SKU-02' then 800 when 'SKU-03' then 400 when 'SKU-04' then 250 else 150 end,8),
   (p_team_id,v_supplier_c,'SUP-C',v_sku.sku,
    case v_sku.sku when 'SKU-01' then 15 when 'SKU-02' then 10 when 'SKU-03' then 35 when 'SKU-04' then 43.75 else 60 end,
    case v_sku.sku when 'SKU-03' then 20 when 'SKU-04' then 10 when 'SKU-05' then 5 else 25 end,
    case v_sku.sku when 'SKU-01' then 500 when 'SKU-02' then 600 when 'SKU-03' then 300 when 'SKU-04' then 200 else 100 end,5);
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
  jsonb_build_object('horizon_days',30,'round_days',10,'demand_shock_pct',40,'supplier_a_delay_days',10,'sku_count',5,'opening_capital',190000));
 return jsonb_build_object('team_id',p_team_id,'sku_count',5,'supplier_count',3,'demand_units',9800,'opening_stock_units',1850);
end; $$;

create or replace function public.amazon_place_purchase_order(
 p_team_id uuid,p_supplier_code text,p_sku text,p_quantity integer,p_order_day integer default null
) returns uuid language plpgsql security definer set search_path=''
as $$
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
 if v_arrival>v_clock.virtual_now+make_interval(days=>greatest(0,3-v_clock.current_round)*10+10) then raise exception 'Arrival is outside the 30-day case horizon'; end if;
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
end; $$;

create or replace function public.amazon_receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_po public.competition_purchase_orders%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_new integer; v_stock integer; v_cost numeric; v_item text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only Warehouse Manager can receive stock'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_po.competition_id for update;
 if v_clock.virtual_now<coalesce(v_po.available_at,v_po.expected_at) then raise exception 'Supplier delivery is not available yet'; end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 select item_name into v_item from public.amazon_case_skus where sku=v_po.sku;
 v_cost:=p_quantity*v_po.unit_cost;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_item,'finished_goods',p_quantity,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new:=v_po.received_quantity+p_quantity;
 update public.competition_purchase_orders set received_quantity=v_new,status=case when v_new=quantity then 'received' else 'partially_received' end,
 received_at=case when v_new=quantity then v_clock.virtual_now else received_at end where id=p_purchase_order_id;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'purchase',-v_cost,'Amazon finished goods received',p_purchase_order_id);
 return jsonb_build_object('received_quantity',v_new,'stock_quantity',v_stock,'cost',v_cost);
end; $$;

create or replace function public.amazon_set_posture(p_team_id uuid,p_posture text)
returns text language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not public.is_competition_role(v_team.competition_id,p_team_id,array['procurement']) then raise exception 'Only Procurement Manager can request a strategy change'; end if;
 if p_posture not in ('cost_focused','balanced','service_focused') then raise exception 'Invalid procurement posture'; end if;
 update public.amazon_case_team_state set strategic_posture=p_posture where team_id=p_team_id;
 return p_posture;
end; $$;

create or replace function public.amazon_advance_round(p_competition_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_classroom uuid; v_status text; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom,v_status from public.competitions where id=p_competition_id;
 if not public.is_class_teacher(v_classroom) then raise exception 'Only teacher can advance rounds'; end if;
 if v_status<>'active' then raise exception 'Competition must be active'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if v_clock.current_round>=3 then raise exception 'Final round reached'; end if;
 update public.competition_rounds set status='completed' where competition_id=p_competition_id and round_number=v_clock.current_round;
 update public.competition_simulation_clock set current_round=current_round+1,virtual_now=virtual_now+interval '10 days',updated_at=now()
 where competition_id=p_competition_id returning * into v_clock;
 update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;
 update public.amazon_case_approvals set status='expired',resolved_at=now() where competition_id=p_competition_id and status='pending';
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select p_competition_id,t.id,t.classroom_id,(select auth.uid()),'teacher','amazon_round_advanced',
 'Amazon case advanced to round '||v_clock.current_round,jsonb_build_object('round',v_clock.current_round,'days_advanced',10,'virtual_now',v_clock.virtual_now)
 from public.competition_teams t where t.competition_id=p_competition_id;
 return jsonb_build_object('current_round',v_clock.current_round,'round_limit',3,'days_advanced',10,'virtual_now',v_clock.virtual_now);
end; $$;

grant execute on function public.amazon_initialize_team(uuid) to authenticated;
grant execute on function public.amazon_place_purchase_order(uuid,text,text,integer,integer) to authenticated;
grant execute on function public.amazon_receive_purchase_order(uuid,integer) to authenticated;
grant execute on function public.amazon_set_posture(uuid,text) to authenticated;
grant execute on function public.amazon_advance_round(uuid) to authenticated;
