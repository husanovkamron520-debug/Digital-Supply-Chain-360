-- Applied competition operational migrations, in exact database application order.
-- Requires supabase/competition_engine.sql first.

-- ===== competition_team_member_rls_recursion_fix =====

create or replace function public.is_competition_team_member(p_competition_id uuid,p_team_id uuid)
returns boolean
language sql stable security definer
set search_path=''
as $$
 select exists (
  select 1 from public.competition_team_members m
  where m.competition_id=p_competition_id
   and m.team_id=p_team_id
   and m.student_id=(select auth.uid())
 );
$$;
revoke all on function public.is_competition_team_member(uuid,uuid) from public,anon;
grant execute on function public.is_competition_team_member(uuid,uuid) to authenticated;

drop policy if exists competition_team_members_read_scope on public.competition_team_members;
create policy competition_team_members_read_scope on public.competition_team_members
 for select to authenticated using (
  student_id=(select auth.uid())
  or public.is_class_teacher(classroom_id)
  or public.is_competition_team_member(competition_id,team_id)
);


-- ===== competition_balanced_team_setup_and_evaluation =====

create or replace function public.create_balanced_competition_teams(p_competition_id uuid,p_team_count integer default 4)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_no integer; v_role_no integer; v_roles text[]:=array['procurement','manufacturer','warehouse','transport','operations'];
 v_idx integer:=0; v_role text; v_student_assignments integer:=0;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then raise exception 'Teams already exist; use manual assignment instead';
 end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_student_count<p_team_count then raise exception 'Not enough students to create balanced teams'; end if;
 for v_template in
  select id,name from public.company_templates where active order by
   case slug when 'lean-automotive' then 1 when 'omnichannel-retail' then 2 when 'flatpack-global' then 3 when 'beverage-fast-moving' then 4 else 5 end
  limit p_team_count
 loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Team '||v_created||' · '||v_template.name)
  returning id into v_team_ids[v_created];
  v_team_names:=array_append(v_team_names,'Team '||v_created||' · '||v_template.name);
 end loop;
 if v_created<>p_team_count then raise exception 'Not enough active company templates'; end if;
 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id
  order by joined_at,student_id
 loop
  v_idx:=v_member.rn;
  v_team_no:=((v_idx-1) % p_team_count)+1;
  v_role_no:=(((v_idx-1) / p_team_count) % array_length(v_roles,1))+1;
  v_role:=v_roles[v_role_no];
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_role);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,
  'student_count',v_student_assignments,'team_names',to_jsonb(v_team_names));
end; $$;
revoke all on function public.create_balanced_competition_teams(uuid,integer) from public,anon;
grant execute on function public.create_balanced_competition_teams(uuid,integer) to authenticated;

create or replace function public.evaluate_competition_decision(
 p_decision_id uuid,p_score numeric,p_feedback text default ''
) returns boolean language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id into v_classroom_id from public.competition_decisions where id=p_decision_id for update;
 if not found then raise exception 'Decision not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can evaluate decisions'; end if;
 if p_score is null or p_score<0 or p_score>100 then raise exception 'Score must be between 0 and 100'; end if;
 update public.competition_decisions set score=round(p_score,2),feedback=left(coalesce(p_feedback,''),2000),
  evaluated_by=(select auth.uid()),evaluated_at=now() where id=p_decision_id;
 return true;
end; $$;
revoke all on function public.evaluate_competition_decision(uuid,numeric,text) from public,anon;
grant execute on function public.evaluate_competition_decision(uuid,numeric,text) to authenticated;


-- ===== competition_team_operational_simulation =====

-- Team-isolated operational simulation layer. Existing classroom data remains untouched.
alter table public.competition_teams
 add column if not exists starting_capital numeric(14,2) not null default 100000,
 add column if not exists cash_balance numeric(14,2) not null default 100000,
 add column if not exists production_capacity_units integer not null default 1000;

create table if not exists public.competition_suppliers(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 supplier_code text not null,name text not null,lead_time_days integer not null check(lead_time_days between 1 and 90),
 unit_cost numeric(12,2) not null check(unit_cost>0),reliability_score numeric(5,2) not null check(reliability_score between 0 and 100),
 active boolean not null default true,created_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade,
 unique(team_id,supplier_code)
);
create table if not exists public.competition_inventory(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 sku text not null,item_name text not null,item_type text not null check(item_type in('raw_material','finished_goods')),
 quantity integer not null default 0 check(quantity>=0),reorder_level integer not null default 0 check(reorder_level>=0),
 unit_cost numeric(12,2) not null default 0 check(unit_cost>=0),updated_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade,
 unique(team_id,sku)
);
create table if not exists public.competition_purchase_orders(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 supplier_id uuid not null references public.competition_suppliers(id),po_number text not null,
 sku text not null,item_name text not null,quantity integer not null check(quantity between 1 and 1000000),
 received_quantity integer not null default 0 check(received_quantity>=0),unit_cost numeric(12,2) not null check(unit_cost>=0),
 status text not null default 'placed' check(status in('placed','partially_received','received','cancelled')),
 expected_at timestamptz not null,created_at timestamptz not null default now(),received_at timestamptz,
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade,
 unique(team_id,po_number),check(received_quantity<=quantity)
);
create table if not exists public.competition_customer_orders(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 order_number text not null,sku text not null,item_name text not null,quantity integer not null check(quantity between 1 and 1000000),
 unit_price numeric(12,2) not null check(unit_price>0),
 status text not null default 'open' check(status in('open','partially_shipped','in_transit','delivered','cancelled')),
 due_at timestamptz not null,created_at timestamptz not null default now(),delivered_at timestamptz,
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade,
 unique(team_id,order_number)
);
create table if not exists public.competition_production_runs(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 sku text not null,item_name text not null,planned_quantity integer not null check(planned_quantity>0),
 produced_quantity integer not null check(produced_quantity>=0),raw_material_sku text not null,
 material_per_unit numeric(8,3) not null default 1 check(material_per_unit>0),
 conversion_cost_per_unit numeric(12,2) not null default 3 check(conversion_cost_per_unit>=0),
 status text not null default 'completed' check(status in('planned','completed','cancelled')),
 started_at timestamptz not null default now(),completed_at timestamptz,
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);
create table if not exists public.competition_shipments(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 order_id uuid not null references public.competition_customer_orders(id) on delete cascade,
 quantity integer not null check(quantity>0),origin text not null,destination text not null,carrier text not null,
 status text not null default 'in_transit' check(status in('in_transit','delayed','delivered','cancelled')),
 transport_cost numeric(12,2) not null default 0 check(transport_cost>=0),
 eta timestamptz not null,dispatched_at timestamptz not null default now(),delivered_at timestamptz,
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);
create table if not exists public.competition_ledger(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 actor_id uuid references public.profiles(id),entry_type text not null check(entry_type in('capital','purchase','production','transport','revenue','adjustment')),
 amount numeric(14,2) not null,description text not null,reference_id uuid,created_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);
create table if not exists public.competition_operational_events(
 id bigint generated always as identity primary key,competition_id uuid not null,team_id uuid not null,classroom_id uuid not null,
 actor_id uuid references public.profiles(id),actor_role text,event_type text not null,description text not null,
 metadata jsonb not null default '{}'::jsonb,created_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);

create index if not exists comp_suppliers_team_idx on public.competition_suppliers(team_id,active);
create index if not exists comp_inventory_team_idx on public.competition_inventory(team_id,item_type);
create index if not exists comp_po_team_idx on public.competition_purchase_orders(team_id,created_at desc);
create index if not exists comp_customer_orders_team_idx on public.competition_customer_orders(team_id,created_at desc);
create index if not exists comp_production_team_idx on public.competition_production_runs(team_id,started_at desc);
create index if not exists comp_shipments_team_idx on public.competition_shipments(team_id,status);
create index if not exists comp_ledger_team_idx on public.competition_ledger(team_id,created_at desc);
create index if not exists comp_events_team_idx on public.competition_operational_events(team_id,created_at desc);

create or replace function public.is_competition_role(p_competition_id uuid,p_team_id uuid,p_roles text[])
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id
  and m.team_id=p_team_id and m.student_id=(select auth.uid()) and m.operational_role=any(p_roles));
$$;
revoke all on function public.is_competition_role(uuid,uuid,text[]) from public,anon;
grant execute on function public.is_competition_role(uuid,uuid,text[]) to authenticated;

alter table public.competition_suppliers enable row level security;
alter table public.competition_inventory enable row level security;
alter table public.competition_purchase_orders enable row level security;
alter table public.competition_customer_orders enable row level security;
alter table public.competition_production_runs enable row level security;
alter table public.competition_shipments enable row level security;
alter table public.competition_ledger enable row level security;
alter table public.competition_operational_events enable row level security;

do $$
declare t text;
begin
 foreach t in array array['competition_suppliers','competition_inventory','competition_purchase_orders',
  'competition_customer_orders','competition_production_runs','competition_shipments','competition_ledger','competition_operational_events']
 loop
  execute format('drop policy if exists %I on public.%I',t||'_read_team',t);
  execute format('create policy %I on public.%I for select to authenticated using (public.is_class_teacher(classroom_id) or public.is_competition_team_member(competition_id,team_id))',t||'_read_team',t);
 end loop;
end $$;

revoke all on public.competition_suppliers,public.competition_inventory,public.competition_purchase_orders,
 public.competition_customer_orders,public.competition_production_runs,public.competition_shipments,
 public.competition_ledger,public.competition_operational_events from anon,authenticated;
grant select on public.competition_suppliers,public.competition_inventory,public.competition_purchase_orders,
 public.competition_customer_orders,public.competition_production_runs,public.competition_shipments,
 public.competition_ledger,public.competition_operational_events to authenticated;

create or replace function public.initialize_competition_team()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_profile jsonb; v_template_name text;
begin
 select operating_profile,name into v_profile,v_template_name from public.company_templates where id=new.company_template_id;
 update public.competition_teams set
  starting_capital=100000,cash_balance=100000,
  production_capacity_units=coalesce((v_profile->>'capacity_units_per_round')::integer,1000)
 where id=new.id;
 insert into public.competition_suppliers(competition_id,team_id,classroom_id,supplier_code,name,lead_time_days,unit_cost,reliability_score)
 values
 (new.competition_id,new.id,new.classroom_id,'SUP-A','Local Components Co.',3,8.00,96),
 (new.competition_id,new.id,new.classroom_id,'SUP-B','Regional Industrial Supply',6,7.00,90),
 (new.competition_id,new.id,new.classroom_id,'SUP-C','Global Value Materials',10,6.25,82);
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values
 (new.competition_id,new.id,new.classroom_id,'RM-001','Core raw material','raw_material',500,200,8.00),
 (new.competition_id,new.id,new.classroom_id,'FG-001','Finished product','finished_goods',100,60,25.00);
 insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
 values
 (new.competition_id,new.id,new.classroom_id,'CUST-001','FG-001','Finished product',100,42,now()+interval '5 days'),
 (new.competition_id,new.id,new.classroom_id,'CUST-002','FG-001','Finished product',150,42,now()+interval '7 days'),
 (new.competition_id,new.id,new.classroom_id,'CUST-003','FG-001','Finished product',200,42,now()+interval '9 days');
 insert into public.competition_ledger(competition_id,team_id,classroom_id,entry_type,amount,description)
 values(new.competition_id,new.id,new.classroom_id,'capital',100000,'Initial company capital');
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,event_type,description,metadata)
 values(new.competition_id,new.id,new.classroom_id,'company_initialized','Company simulation initialized',
  jsonb_build_object('company_template',v_template_name,'capital',100000,'inventory_skus',2,'seed_customer_orders',3));
 return new;
end; $$;
drop trigger if exists initialize_competition_team_after_insert on public.competition_teams;
create trigger initialize_competition_team_after_insert after insert on public.competition_teams
for each row execute function public.initialize_competition_team();

create or replace function public.competition_create_purchase_order(
 p_team_id uuid,p_supplier_id uuid,p_sku text,p_item_name text,p_quantity integer
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_supplier public.competition_suppliers%rowtype; v_id uuid; v_po text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['procurement']) then raise exception 'Only the assigned Procurement Manager can create purchase orders'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id and team_id=p_team_id and active;
 if not found then raise exception 'Active supplier not found for this team'; end if;
 if p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Quantity must be 1-100,000'; end if;
 if char_length(trim(coalesce(p_sku,''))) not between 2 and 40 or char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 then raise exception 'Invalid SKU or item name'; end if;
 v_po:='PO-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.competition_purchase_orders(competition_id,team_id,classroom_id,supplier_id,po_number,sku,item_name,quantity,unit_cost,expected_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,v_supplier.id,v_po,upper(trim(p_sku)),trim(p_item_name),p_quantity,v_supplier.unit_cost,now()+make_interval(days=>v_supplier.lead_time_days))
 returning id into v_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'procurement','purchase_order_placed','Purchase order '||v_po||' placed',
 jsonb_build_object('supplier',v_supplier.name,'quantity',p_quantity,'unit_cost',v_supplier.unit_cost,'lead_time_days',v_supplier.lead_time_days));
 return v_id;
end; $$;

create or replace function public.competition_receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_po public.competition_purchase_orders%rowtype; v_team public.competition_teams%rowtype; v_new integer; v_stock integer; v_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only the assigned Warehouse Manager can receive stock'; end if;
 if v_po.status='cancelled' or v_po.status='received' then raise exception 'Purchase order cannot be received'; end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 v_cost:=p_quantity*v_po.unit_cost;
 select * into v_team from public.competition_teams where id=v_po.team_id for update;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash to pay for this receipt'; end if;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_po.item_name,'raw_material',p_quantity,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set quantity=competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new:=v_po.received_quantity+p_quantity;
 update public.competition_purchase_orders set received_quantity=v_new,status=case when v_new=quantity then 'received' else 'partially_received' end,
 received_at=case when v_new=quantity then now() else received_at end where id=p_purchase_order_id;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'purchase',-v_cost,'Received '+p_quantity||' units of '||v_po.sku,p_purchase_order_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'warehouse','purchase_order_received','Received '||p_quantity||' units of '||v_po.sku,
 jsonb_build_object('stock_after',v_stock,'cost',v_cost,'po_id',p_purchase_order_id));
 return jsonb_build_object('received_quantity',v_new,'stock_quantity',v_stock,'cost',v_cost);
end; $$;

create or replace function public.competition_complete_production(p_team_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_raw integer; v_fg integer; v_cost numeric; v_run uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['manufacturer']) then raise exception 'Only the assigned Production Manager can run production'; end if;
 if p_quantity is null or p_quantity not between 1 and v_team.production_capacity_units then raise exception 'Production quantity exceeds the per-round capacity'; end if;
 select quantity into v_raw from public.competition_inventory where team_id=p_team_id and sku='RM-001' for update;
 if not found or v_raw<p_quantity then raise exception 'Insufficient raw materials. Purchase and receive more first.'; end if;
 v_cost:=p_quantity*3;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash for production'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=p_team_id and sku='RM-001';
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001','Finished product','finished_goods',p_quantity,60,25)
 on conflict(team_id,sku) do update set quantity=competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_fg;
 insert into public.competition_production_runs(competition_id,team_id,classroom_id,sku,item_name,planned_quantity,produced_quantity,raw_material_sku,conversion_cost_per_unit,status,completed_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001','Finished product',p_quantity,p_quantity,'RM-001',3,'completed',now())
 returning id into v_run;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'production',-v_cost,'Production conversion cost',v_run);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'manufacturer','production_completed','Produced '||p_quantity||' finished units',
 jsonb_build_object('production_run_id',v_run,'raw_material_remaining',v_raw-p_quantity,'finished_stock',v_fg,'cost',v_cost));
 return jsonb_build_object('production_run_id',v_run,'produced_quantity',p_quantity,'finished_stock',v_fg,'raw_material_remaining',v_raw-p_quantity,'cost',v_cost);
end; $$;

create or replace function public.competition_create_customer_order(
 p_team_id uuid,p_order_number text,p_sku text,p_item_name text,p_quantity integer,p_unit_price numeric,p_due_at timestamptz
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['retailer','customer','operations']) then raise exception 'Only Customer/Retail Operations can create orders'; end if;
 if char_length(trim(coalesce(p_order_number,''))) not between 3 and 40 or char_length(trim(coalesce(p_sku,''))) not between 2 and 40 then raise exception 'Invalid order number or SKU'; end if;
 if char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 or p_quantity not between 1 and 100000 then raise exception 'Invalid item or quantity'; end if;
 if p_unit_price is null or p_unit_price<=0 or p_unit_price>1000000 or p_due_at is null or p_due_at<=now() then raise exception 'Invalid price or due date'; end if;
 insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,upper(trim(p_order_number)),upper(trim(p_sku)),trim(p_item_name),p_quantity,p_unit_price,p_due_at)
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Order number already exists for this team';
end; $$;

create or replace function public.competition_dispatch_shipment(
 p_order_id uuid,p_quantity integer,p_origin text,p_destination text,p_carrier text,p_transport_cost numeric default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_order public.competition_customer_orders%rowtype; v_stock integer; v_shipped integer; v_id uuid; v_role text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can dispatch shipments'; end if;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then raise exception 'Invalid shipment details'; end if;
 if p_transport_cost is null or p_transport_cost<0 or p_transport_cost>10000000 then raise exception 'Invalid transport cost'; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 if v_shipped+p_quantity>v_order.quantity then raise exception 'Shipment quantity exceeds the outstanding customer order'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,trim(p_origin),trim(p_destination),trim(p_carrier),p_transport_cost,now()+interval '2 days')
 returning id into v_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-p_transport_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-p_transport_cost,'Shipment transport cost',v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','shipment_dispatched','Dispatched '||p_quantity||' units to '||p_destination,
 jsonb_build_object('shipment_id',v_id,'order_id',p_order_id,'stock_after',v_stock-p_quantity,'transport_cost',p_transport_cost));
 return v_id;
end; $$;

create or replace function public.competition_deliver_shipment(p_shipment_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_ship public.competition_shipments%rowtype; v_order public.competition_customer_orders%rowtype; v_delivered integer; v_revenue numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_ship from public.competition_shipments where id=p_shipment_id for update;
 if not found then raise exception 'Shipment not found'; end if;
 if not public.is_competition_role(v_ship.competition_id,v_ship.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can confirm delivery'; end if;
 if v_ship.status='delivered' then raise exception 'Shipment is already delivered'; end if;
 if v_ship.status='cancelled' then raise exception 'Cancelled shipment cannot be delivered'; end if;
 select * into v_order from public.competition_customer_orders where id=v_ship.order_id for update;
 update public.competition_shipments set status='delivered',delivered_at=now() where id=p_shipment_id;
 select coalesce(sum(quantity),0) into v_delivered from public.competition_shipments where order_id=v_ship.order_id and status='delivered';
 if v_delivered>=v_order.quantity then
  update public.competition_customer_orders set status='delivered',delivered_at=now() where id=v_order.id;
 else
  update public.competition_customer_orders set status='partially_shipped' where id=v_order.id;
 end if;
 v_revenue:=v_ship.quantity*v_order.unit_price;
 update public.competition_teams set cash_balance=cash_balance+v_revenue where id=v_ship.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'revenue',v_revenue,'Customer delivery revenue',p_shipment_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'transport','shipment_delivered','Shipment delivered to '||v_ship.destination,
 jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',now()<=v_ship.eta,'revenue',v_revenue));
 return jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',now()<=v_ship.eta,'revenue',v_revenue);
end; $$;

create or replace function public.competition_adjust_inventory(p_team_id uuid,p_sku text,p_delta integer,p_reason text default 'Cycle count')
returns integer language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_qty integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['warehouse']) then raise exception 'Only the Warehouse Manager can adjust stock'; end if;
 if p_delta is null or p_delta=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 update public.competition_inventory set quantity=quantity+p_delta,updated_at=now()
 where team_id=p_team_id and sku=upper(trim(p_sku)) and quantity+p_delta>=0 returning quantity into v_qty;
 if not found then raise exception 'SKU not found or adjustment would make stock negative'; end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'warehouse','inventory_adjusted','Stock adjusted: '||p_sku,
 jsonb_build_object('delta',p_delta,'quantity_after',v_qty,'reason',left(coalesce(p_reason,''),300)));
 return v_qty;
end; $$;

do $$
declare f record;
begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in('competition_create_purchase_order','competition_receive_purchase_order',
 'competition_complete_production','competition_create_customer_order','competition_dispatch_shipment',
 'competition_deliver_shipment','competition_adjust_inventory')
 loop
  execute format('revoke all on function %s from public,anon',f.signature);
  execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;


-- ===== competition_supplier_terms_and_financial_checks =====

create or replace function public.competition_update_supplier_terms(
 p_supplier_id uuid,p_lead_time_days integer,p_unit_cost numeric,p_reliability_score numeric
) returns boolean language plpgsql security definer set search_path=''
as $$
declare v_supplier public.competition_suppliers%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id for update;
 if not found then raise exception 'Supplier not found'; end if;
 if not public.is_competition_role(v_supplier.competition_id,v_supplier.team_id,array['supplier','procurement']) then
  raise exception 'Only Supplier Relations or Procurement can negotiate supplier terms';
 end if;
 if p_lead_time_days is null or p_lead_time_days not between 1 and 90 then raise exception 'Lead time must be 1-90 days'; end if;
 if p_unit_cost is null or p_unit_cost<=0 or p_unit_cost>1000000 then raise exception 'Unit cost must be positive'; end if;
 if p_reliability_score is null or p_reliability_score not between 0 and 100 then raise exception 'Reliability must be 0-100'; end if;
 update public.competition_suppliers set lead_time_days=p_lead_time_days,unit_cost=p_unit_cost,reliability_score=p_reliability_score
 where id=p_supplier_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_supplier.competition_id,v_supplier.team_id,v_supplier.classroom_id,(select auth.uid()),'supplier','supplier_terms_updated',
  'Supplier terms negotiated: '||v_supplier.name,jsonb_build_object('supplier_id',p_supplier_id,'lead_time_days',p_lead_time_days,'unit_cost',p_unit_cost,'reliability',p_reliability_score));
 return true;
end; $$;
revoke all on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) from public,anon;
grant execute on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) to authenticated;

create or replace function public.competition_receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_po public.competition_purchase_orders%rowtype; v_team public.competition_teams%rowtype; v_new integer; v_stock integer; v_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only the assigned Warehouse Manager can receive stock'; end if;
 if v_po.status in('cancelled','received') then raise exception 'Purchase order cannot be received'; end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 v_cost:=p_quantity*v_po.unit_cost;
 select * into v_team from public.competition_teams where id=v_po.team_id for update;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash to pay for this receipt'; end if;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_po.item_name,'raw_material',p_quantity,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new:=v_po.received_quantity+p_quantity;
 update public.competition_purchase_orders set received_quantity=v_new,status=case when v_new=quantity then 'received' else 'partially_received' end,
 received_at=case when v_new=quantity then now() else received_at end where id=p_purchase_order_id;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'purchase',-v_cost,'Received '||p_quantity||' units of '||v_po.sku,p_purchase_order_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,(select auth.uid()),'warehouse','purchase_order_received','Received '||p_quantity||' units of '||v_po.sku,
 jsonb_build_object('stock_after',v_stock,'cost',v_cost,'po_id',p_purchase_order_id));
 return jsonb_build_object('received_quantity',v_new,'stock_quantity',v_stock,'cost',v_cost);
end; $$;

create or replace function public.competition_dispatch_shipment(
 p_order_id uuid,p_quantity integer,p_origin text,p_destination text,p_carrier text,p_transport_cost numeric default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_order public.competition_customer_orders%rowtype; v_stock integer; v_shipped integer; v_id uuid; v_cash numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can dispatch shipments'; end if;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then raise exception 'Invalid shipment details'; end if;
 if p_transport_cost is null or p_transport_cost<0 or p_transport_cost>10000000 then raise exception 'Invalid transport cost'; end if;
 select coalesce(sum(quantity),0) into v_shipped from public.competition_shipments where order_id=p_order_id and status<>'cancelled';
 if v_shipped+p_quantity>v_order.quantity then raise exception 'Shipment quantity exceeds the outstanding customer order'; end if;
 select quantity into v_stock from public.competition_inventory where team_id=v_order.team_id and sku=v_order.sku and item_type='finished_goods' for update;
 if not found or v_stock<p_quantity then raise exception 'Insufficient finished-goods stock'; end if;
 select cash_balance into v_cash from public.competition_teams where id=v_order.team_id for update;
 if v_cash<p_transport_cost then raise exception 'Insufficient company cash for transport'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=v_order.team_id and sku=v_order.sku;
 insert into public.competition_shipments(competition_id,team_id,classroom_id,order_id,quantity,origin,destination,carrier,transport_cost,eta)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,p_order_id,p_quantity,trim(p_origin),trim(p_destination),trim(p_carrier),p_transport_cost,now()+interval '2 days')
 returning id into v_id;
 update public.competition_customer_orders set status='in_transit' where id=p_order_id and status<>'delivered';
 update public.competition_teams set cash_balance=cash_balance-p_transport_cost where id=v_order.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport',-p_transport_cost,'Shipment transport cost',v_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_order.competition_id,v_order.team_id,v_order.classroom_id,(select auth.uid()),'transport','shipment_dispatched','Dispatched '||p_quantity||' units to '||p_destination,
 jsonb_build_object('shipment_id',v_id,'order_id',p_order_id,'stock_after',v_stock-p_quantity,'transport_cost',p_transport_cost));
 return v_id;
end; $$;


-- ===== competition_live_metrics_and_weighted_scoring =====

create or replace view public.competition_team_live_metrics
with (security_invoker=true)
as
with order_metrics as (
 select team_id,count(*)::integer as total_orders,
  count(*) filter(where status='delivered')::integer as delivered_orders,
  coalesce(sum(quantity) filter(where status='delivered'),0)::numeric as delivered_units,
  coalesce(sum(quantity) filter(where status='delivered' and delivered_at<=due_at),0)::numeric as on_time_units,
  avg(extract(epoch from (delivered_at-created_at))/86400.0) filter(where status='delivered') as avg_delivery_days
 from public.competition_customer_orders group by team_id
), inventory_metrics as (
 select team_id,count(*)::integer as sku_count,
  count(*) filter(where quantity>reorder_level)::integer as healthy_skus,
  coalesce(sum(quantity),0)::numeric as inventory_units,
  coalesce(sum(quantity*unit_cost),0)::numeric as inventory_value,
  count(*) filter(where quantity<=reorder_level)::integer as low_stock_skus
 from public.competition_inventory group by team_id
), production_metrics as (
 select team_id,coalesce(sum(produced_quantity),0)::numeric as produced_units,
  count(*)::integer as production_runs
 from public.competition_production_runs where status='completed' group by team_id
), finance_metrics as (
 select team_id,coalesce(sum(amount) filter(where entry_type='revenue'),0)::numeric as revenue,
  coalesce(-sum(amount) filter(where entry_type in('purchase','production','transport')),0)::numeric as operating_cost
 from public.competition_ledger group by team_id
), decision_metrics as (
 select team_id,avg(score)::numeric as decision_quality,count(*)::integer as decision_count,
  count(*) filter(where score is not null)::integer as evaluated_decisions
 from public.competition_decisions group by team_id
), raw as (
 select t.id as team_id,t.competition_id,t.classroom_id,t.name as team_name,t.starting_capital,t.cash_balance,
  t.production_capacity_units,ct.name as company_name,ct.scoring_weights,
  coalesce(o.total_orders,0) as total_orders,coalesce(o.delivered_orders,0) as delivered_orders,
  coalesce(o.delivered_units,0) as delivered_units,coalesce(o.on_time_units,0) as on_time_units,
  o.avg_delivery_days,coalesce(i.sku_count,0) as sku_count,coalesce(i.healthy_skus,0) as healthy_skus,
  coalesce(i.inventory_units,0) as inventory_units,coalesce(i.inventory_value,0) as inventory_value,
  coalesce(i.low_stock_skus,0) as low_stock_skus,coalesce(p.produced_units,0) as produced_units,
  coalesce(p.production_runs,0) as production_runs,coalesce(f.revenue,0) as revenue,
  coalesce(f.operating_cost,0) as operating_cost,coalesce(d.decision_count,0) as decision_count,
  coalesce(d.evaluated_decisions,0) as evaluated_decisions,d.decision_quality,
  coalesce((ct.operating_profile->>'baseline_lead_time_days')::numeric,7) as baseline_lead_time_days
 from public.competition_teams t
 join public.company_templates ct on ct.id=t.company_template_id
 left join order_metrics o on o.team_id=t.id
 left join inventory_metrics i on i.team_id=t.id
 left join production_metrics p on p.team_id=t.id
 left join finance_metrics f on f.team_id=t.id
 left join decision_metrics d on d.team_id=t.id
), scored as (
 select r.*,
  case when delivered_units>0 then round(100*on_time_units/delivered_units,2) end as service_score,
  case when starting_capital>0 then greatest(0,least(100,round(50+50*(cash_balance-starting_capital)/starting_capital,2))) end as cost_score,
  case when sku_count>0 then round(100.0*healthy_skus/sku_count,2) end as inventory_score,
  case when avg_delivery_days>0 then least(100,round(100*baseline_lead_time_days/avg_delivery_days,2)) end as lead_time_score,
  case when production_runs>0 and production_capacity_units>0 then least(100,round(100*produced_units/production_capacity_units,2)) end as productivity_score,
  round(decision_quality,2) as decision_quality_score
 from raw r
), weighted as (
 select s.*,
  (case when service_score is not null then coalesce((scoring_weights->>'service')::numeric,25) else 0 end+
   case when cost_score is not null then coalesce((scoring_weights->>'cost')::numeric,20) else 0 end+
   case when inventory_score is not null then coalesce((scoring_weights->>'inventory')::numeric,15) else 0 end+
   case when lead_time_score is not null then coalesce((scoring_weights->>'lead_time')::numeric,15) else 0 end+
   case when productivity_score is not null then coalesce((scoring_weights->>'productivity')::numeric,10) else 0 end+
   case when decision_quality_score is not null then coalesce((scoring_weights->>'decision_quality')::numeric,15) else 0 end) as available_weight,
  (coalesce(service_score,0)*coalesce((scoring_weights->>'service')::numeric,25)+
   coalesce(cost_score,0)*coalesce((scoring_weights->>'cost')::numeric,20)+
   coalesce(inventory_score,0)*coalesce((scoring_weights->>'inventory')::numeric,15)+
   coalesce(lead_time_score,0)*coalesce((scoring_weights->>'lead_time')::numeric,15)+
   coalesce(productivity_score,0)*coalesce((scoring_weights->>'productivity')::numeric,10)+
   coalesce(decision_quality_score,0)*coalesce((scoring_weights->>'decision_quality')::numeric,15)) as weighted_sum
 from scored s
)
select team_id,competition_id,classroom_id,team_name,company_name,starting_capital,cash_balance,
 total_orders,delivered_orders,delivered_units,on_time_units,avg_delivery_days,
 sku_count,healthy_skus,inventory_units,inventory_value,low_stock_skus,produced_units,production_runs,
 revenue,operating_cost,decision_count,evaluated_decisions,decision_quality,
 service_score,cost_score,inventory_score,lead_time_score,productivity_score,decision_quality_score,
 round(100.0*available_weight/100,2) as score_coverage_pct,
 case when available_weight>0 then round(weighted_sum/available_weight,2) end as total_score,
 jsonb_build_object('service',service_score,'cost',cost_score,'inventory',inventory_score,
  'lead_time',lead_time_score,'productivity',productivity_score,'decision_quality',decision_quality_score) as component_scores
from weighted;

grant select on public.competition_team_live_metrics to authenticated;

create or replace function public.calculate_competition_scores(p_competition_id uuid,p_round_number integer default 1)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_saved integer:=0; r record;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_round_number is null or p_round_number not between 1 and 20 then raise exception 'Round number must be 1-20'; end if;
 select classroom_id into v_classroom_id from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can calculate official scores'; end if;
 for r in select * from public.competition_team_live_metrics where competition_id=p_competition_id and total_score is not null
 loop
  insert into public.competition_score_snapshots(competition_id,team_id,round_number,metrics,component_scores,total_score)
  values(p_competition_id,r.team_id,p_round_number,
   jsonb_build_object('orders',r.total_orders,'delivered_orders',r.delivered_orders,'delivered_units',r.delivered_units,
    'on_time_units',r.on_time_units,'average_delivery_days',r.avg_delivery_days,'inventory_units',r.inventory_units,
    'low_stock_skus',r.low_stock_skus,'produced_units',r.produced_units,'production_runs',r.production_runs,
    'revenue',r.revenue,'operating_cost',r.operating_cost,'evaluated_decisions',r.evaluated_decisions,
    'coverage_pct',r.score_coverage_pct),
   r.component_scores,r.total_score)
  on conflict(competition_id,team_id,round_number) do update set metrics=excluded.metrics,
   component_scores=excluded.component_scores,total_score=excluded.total_score,calculated_at=now();
  v_saved:=v_saved+1;
 end loop;
 return v_saved;
end; $$;
revoke all on function public.calculate_competition_scores(uuid,integer) from public,anon;
grant execute on function public.calculate_competition_scores(uuid,integer) to authenticated;


-- ===== competition_role_balancing_supplier_manager =====

create or replace function public.create_balanced_competition_teams(p_competition_id uuid,p_team_count integer default 4)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_no integer; v_role_no integer;
 v_roles text[]:=array['procurement','supplier','manufacturer','warehouse','transport'];
 v_idx integer:=0; v_student_assignments integer:=0;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then raise exception 'Teams already exist; use manual assignment instead'; end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_student_count<p_team_count then raise exception 'Not enough students to create balanced teams'; end if;
 for v_template in
  select id,name from public.company_templates where active order by
   case slug when 'lean-automotive' then 1 when 'omnichannel-retail' then 2 when 'flatpack-global' then 3 when 'beverage-fast-moving' then 4 else 5 end
  limit p_team_count
 loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Team '||v_created||' · '||v_template.name)
  returning id into v_team_ids[v_created];
  v_team_names:=array_append(v_team_names,'Team '||v_created||' · '||v_template.name);
 end loop;
 if v_created<>p_team_count then raise exception 'Not enough active company templates'; end if;
 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id order by joined_at,student_id
 loop
  v_idx:=v_member.rn;v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,'student_count',v_student_assignments,'team_names',to_jsonb(v_team_names));
end; $$;


-- ===== competition_virtual_clock_and_round_progression =====

create table if not exists public.competition_simulation_clock(
 competition_id uuid primary key references public.competitions(id) on delete cascade,
 classroom_id uuid not null references public.classrooms(id) on delete cascade,
 current_round integer not null default 1 check(current_round between 1 and 20),
 round_limit integer not null default 4 check(round_limit between 1 and 20),
 virtual_now timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.competition_simulation_clock enable row level security;
drop policy if exists competition_clock_read_class on public.competition_simulation_clock;
create policy competition_clock_read_class on public.competition_simulation_clock for select to authenticated
 using(public.is_class_member(classroom_id));
revoke all on public.competition_simulation_clock from anon,authenticated;
grant select on public.competition_simulation_clock to authenticated;

create or replace function public.initialize_competition_rounds()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_rounds integer;
begin
 if old.status='draft' and new.status='active' then
  v_rounds:=greatest(1,least(20,coalesce((new.settings->>'round_count')::integer,4)));
  insert into public.competition_simulation_clock(competition_id,classroom_id,current_round,round_limit,virtual_now)
  values(new.id,new.classroom_id,1,v_rounds,now()) on conflict(competition_id) do nothing;
  insert into public.competition_rounds(competition_id,round_number,title,status,brief)
  select new.id,n,
   case n when 1 then 'Round 1 · Source & plan' when 2 then 'Round 2 · Produce & replenish'
    when 3 then 'Round 3 · Fulfil & deliver' when 4 then 'Round 4 · Optimise & recover'
    else 'Round '||n||' · Continuous improvement' end,
   case when n=1 then 'active' else 'locked' end,
   jsonb_build_object('round',n,'virtual_days_advanced_after_round',2,
    'focus',case n when 1 then 'Supplier selection, sourcing and inventory policy'
     when 2 then 'Production planning and stock availability'
     when 3 then 'Customer fulfilment and transport execution'
     when 4 then 'Cost, service and risk optimisation' else 'Cross-functional performance' end)
  from generate_series(1,v_rounds) n
  on conflict(competition_id,round_number) do nothing;
 end if;
 return new;
end; $$;
drop trigger if exists competition_initialize_rounds on public.competitions;
create trigger competition_initialize_rounds after update of status on public.competitions
for each row execute function public.initialize_competition_rounds();

create or replace function public.competition_advance_round(p_competition_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can advance the simulation'; end if;
 if v_status<>'active' then raise exception 'Competition must be active to advance a round'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if not found then raise exception 'Simulation clock has not been initialized'; end if;
 if v_clock.current_round>=v_clock.round_limit then raise exception 'Final round reached. Review scores and complete the competition'; end if;
 update public.competition_rounds set status='completed' where competition_id=p_competition_id and round_number=v_clock.current_round;
 update public.competition_simulation_clock set current_round=current_round+1,virtual_now=virtual_now+interval '2 days',updated_at=now()
 where competition_id=p_competition_id returning * into v_clock;
 update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select p_competition_id,t.id,t.classroom_id,(select auth.uid()),'teacher','round_advanced',
  'Simulation advanced to round '||v_clock.current_round,
  jsonb_build_object('round',v_clock.current_round,'virtual_now',v_clock.virtual_now)
 from public.competition_teams t where t.competition_id=p_competition_id;
 return jsonb_build_object('current_round',v_clock.current_round,'round_limit',v_clock.round_limit,'virtual_now',v_clock.virtual_now);
end; $$;
revoke all on function public.competition_advance_round(uuid) from public,anon;
grant execute on function public.competition_advance_round(uuid) to authenticated;

create or replace function public.competition_create_purchase_order(
 p_team_id uuid,p_supplier_id uuid,p_sku text,p_item_name text,p_quantity integer
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_supplier public.competition_suppliers%rowtype; v_clock public.competition_simulation_clock%rowtype; v_id uuid; v_po text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['procurement']) then raise exception 'Only the assigned Procurement Manager can create purchase orders'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id and team_id=p_team_id and active;
 if not found then raise exception 'Active supplier not found for this team'; end if;
 if p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Quantity must be 1-100,000'; end if;
 if char_length(trim(coalesce(p_sku,''))) not between 2 and 40 or char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 then raise exception 'Invalid SKU or item name'; end if;
 v_po:='PO-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.competition_purchase_orders(competition_id,team_id,classroom_id,supplier_id,po_number,sku,item_name,quantity,unit_cost,expected_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,v_supplier.id,v_po,upper(trim(p_sku)),trim(p_item_name),p_quantity,v_supplier.unit_cost,v_clock.virtual_now+make_interval(days=>v_supplier.lead_time_days))
 returning id into v_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'procurement','purchase_order_placed','Purchase order '||v_po||' placed',
 jsonb_build_object('supplier',v_supplier.name,'quantity',p_quantity,'unit_cost',v_supplier.unit_cost,'lead_time_days',v_supplier.lead_time_days,'expected_at',v_clock.virtual_now+make_interval(days=>v_supplier.lead_time_days)));
 return v_id;
end; $$;

create or replace function public.competition_receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_po public.competition_purchase_orders%rowtype; v_team public.competition_teams%rowtype; v_clock public.competition_simulation_clock%rowtype; v_new integer; v_stock integer; v_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only the assigned Warehouse Manager can receive stock'; end if;
 if v_po.status in('cancelled','received') then raise exception 'Purchase order cannot be received'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_po.competition_id;
 if v_clock.virtual_now<v_po.expected_at then raise exception 'Supplier lead time has not elapsed. Expected arrival: %',v_po.expected_at; end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 v_cost:=p_quantity*v_po.unit_cost;
 select * into v_team from public.competition_teams where id=v_po.team_id for update;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash to pay for this receipt'; end if;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_po.item_name,'raw_material',p_quantity,0,v_po.unit_cost)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
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
end; $$;

create or replace function public.competition_dispatch_shipment(
 p_order_id uuid,p_quantity integer,p_origin text,p_destination text,p_carrier text,p_transport_cost numeric default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_order public.competition_customer_orders%rowtype; v_stock integer; v_shipped integer; v_id uuid; v_cash numeric; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can dispatch shipments'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then raise exception 'Invalid shipment details'; end if;
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
end; $$;

create or replace function public.competition_deliver_shipment(p_shipment_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_ship public.competition_shipments%rowtype; v_order public.competition_customer_orders%rowtype; v_delivered integer; v_revenue numeric; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_ship from public.competition_shipments where id=p_shipment_id for update;
 if not found then raise exception 'Shipment not found'; end if;
 if not public.is_competition_role(v_ship.competition_id,v_ship.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can confirm delivery'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_ship.competition_id;
 if v_ship.status='delivered' then raise exception 'Shipment is already delivered'; end if;
 if v_ship.status='cancelled' then raise exception 'Cancelled shipment cannot be delivered'; end if;
 if v_clock.virtual_now<v_ship.eta then raise exception 'Shipment is still in transit. Estimated arrival: %',v_ship.eta; end if;
 select * into v_order from public.competition_customer_orders where id=v_ship.order_id for update;
 update public.competition_shipments set status='delivered',delivered_at=v_clock.virtual_now where id=p_shipment_id;
 select coalesce(sum(quantity),0) into v_delivered from public.competition_shipments where order_id=v_ship.order_id and status='delivered';
 if v_delivered>=v_order.quantity then update public.competition_customer_orders set status='delivered',delivered_at=v_clock.virtual_now where id=v_order.id;
 else update public.competition_customer_orders set status='partially_shipped' where id=v_order.id; end if;
 v_revenue:=v_ship.quantity*v_order.unit_price;
 update public.competition_teams set cash_balance=cash_balance+v_revenue where id=v_ship.team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'revenue',v_revenue,'Customer delivery revenue',p_shipment_id);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_ship.competition_id,v_ship.team_id,v_ship.classroom_id,(select auth.uid()),'transport','shipment_delivered','Shipment delivered to '||v_ship.destination,
 jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',v_clock.virtual_now<=v_order.due_at,'revenue',v_revenue));
 return jsonb_build_object('shipment_id',p_shipment_id,'delivered_quantity',v_ship.quantity,'on_time',v_clock.virtual_now<=v_order.due_at,'revenue',v_revenue,'virtual_delivered_at',v_clock.virtual_now);
end; $$;


-- ===== competition_score_readiness_gate =====

create or replace view public.competition_team_live_metrics
with (security_invoker=true)
as
with order_metrics as (
 select team_id,count(*)::integer as total_orders,count(*) filter(where status='delivered')::integer as delivered_orders,
  coalesce(sum(quantity) filter(where status='delivered'),0)::numeric as delivered_units,
  coalesce(sum(quantity) filter(where status='delivered' and delivered_at<=due_at),0)::numeric as on_time_units,
  avg(extract(epoch from (delivered_at-created_at))/86400.0) filter(where status='delivered') as avg_delivery_days
 from public.competition_customer_orders group by team_id
), inventory_metrics as (
 select team_id,count(*)::integer as sku_count,count(*) filter(where quantity>reorder_level)::integer as healthy_skus,
  coalesce(sum(quantity),0)::numeric as inventory_units,coalesce(sum(quantity*unit_cost),0)::numeric as inventory_value,
  count(*) filter(where quantity<=reorder_level)::integer as low_stock_skus
 from public.competition_inventory group by team_id
), production_metrics as (
 select team_id,coalesce(sum(produced_quantity),0)::numeric as produced_units,count(*)::integer as production_runs
 from public.competition_production_runs where status='completed' group by team_id
), finance_metrics as (
 select team_id,coalesce(sum(amount) filter(where entry_type='revenue'),0)::numeric as revenue,
  coalesce(-sum(amount) filter(where entry_type in('purchase','production','transport')),0)::numeric as operating_cost
 from public.competition_ledger group by team_id
), decision_metrics as (
 select team_id,avg(score)::numeric as decision_quality,count(*)::integer as decision_count,
  count(*) filter(where score is not null)::integer as evaluated_decisions
 from public.competition_decisions group by team_id
), raw as (
 select t.id as team_id,t.competition_id,t.classroom_id,t.name as team_name,t.starting_capital,t.cash_balance,
  t.production_capacity_units,ct.name as company_name,ct.scoring_weights,
  coalesce(o.total_orders,0) as total_orders,coalesce(o.delivered_orders,0) as delivered_orders,
  coalesce(o.delivered_units,0) as delivered_units,coalesce(o.on_time_units,0) as on_time_units,o.avg_delivery_days,
  coalesce(i.sku_count,0) as sku_count,coalesce(i.healthy_skus,0) as healthy_skus,coalesce(i.inventory_units,0) as inventory_units,
  coalesce(i.inventory_value,0) as inventory_value,coalesce(i.low_stock_skus,0) as low_stock_skus,
  coalesce(p.produced_units,0) as produced_units,coalesce(p.production_runs,0) as production_runs,
  coalesce(f.revenue,0) as revenue,coalesce(f.operating_cost,0) as operating_cost,
  coalesce(d.decision_count,0) as decision_count,coalesce(d.evaluated_decisions,0) as evaluated_decisions,
  d.decision_quality,coalesce((ct.operating_profile->>'baseline_lead_time_days')::numeric,7) as baseline_lead_time_days
 from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id
 left join order_metrics o on o.team_id=t.id left join inventory_metrics i on i.team_id=t.id
 left join production_metrics p on p.team_id=t.id left join finance_metrics f on f.team_id=t.id
 left join decision_metrics d on d.team_id=t.id
), scored as (
 select r.*,
  case when delivered_units>0 then round(100*on_time_units/delivered_units,2) end as service_score,
  case when starting_capital>0 then greatest(0,least(100,round(50+50*(cash_balance-starting_capital)/starting_capital,2))) end as cost_score,
  case when sku_count>0 then round(100.0*healthy_skus/sku_count,2) end as inventory_score,
  case when avg_delivery_days>0 then least(100,round(100*baseline_lead_time_days/avg_delivery_days,2)) end as lead_time_score,
  case when production_runs>0 and production_capacity_units>0 then least(100,round(100*produced_units/production_capacity_units,2)) end as productivity_score,
  round(decision_quality,2) as decision_quality_score
 from raw r
), weighted as (
 select s.*,
  (case when service_score is not null then coalesce((scoring_weights->>'service')::numeric,25) else 0 end+
   case when cost_score is not null then coalesce((scoring_weights->>'cost')::numeric,20) else 0 end+
   case when inventory_score is not null then coalesce((scoring_weights->>'inventory')::numeric,15) else 0 end+
   case when lead_time_score is not null then coalesce((scoring_weights->>'lead_time')::numeric,15) else 0 end+
   case when productivity_score is not null then coalesce((scoring_weights->>'productivity')::numeric,10) else 0 end+
   case when decision_quality_score is not null then coalesce((scoring_weights->>'decision_quality')::numeric,15) else 0 end) as available_weight,
  (coalesce(service_score,0)*coalesce((scoring_weights->>'service')::numeric,25)+
   coalesce(cost_score,0)*coalesce((scoring_weights->>'cost')::numeric,20)+
   coalesce(inventory_score,0)*coalesce((scoring_weights->>'inventory')::numeric,15)+
   coalesce(lead_time_score,0)*coalesce((scoring_weights->>'lead_time')::numeric,15)+
   coalesce(productivity_score,0)*coalesce((scoring_weights->>'productivity')::numeric,10)+
   coalesce(decision_quality_score,0)*coalesce((scoring_weights->>'decision_quality')::numeric,15)) as weighted_sum
 from scored s
)
select team_id,competition_id,classroom_id,team_name,company_name,starting_capital,cash_balance,total_orders,delivered_orders,
 delivered_units,on_time_units,avg_delivery_days,sku_count,healthy_skus,inventory_units,inventory_value,low_stock_skus,
 produced_units,production_runs,revenue,operating_cost,decision_count,evaluated_decisions,decision_quality,
 service_score,cost_score,inventory_score,lead_time_score,productivity_score,decision_quality_score,
 round(available_weight,2) as score_coverage_pct,
 case when delivered_orders>0 and production_runs>0 and evaluated_decisions>0 and available_weight>0
  then round(weighted_sum/available_weight,2) end as total_score,
 jsonb_build_object('service',service_score,'cost',cost_score,'inventory',inventory_score,
  'lead_time',lead_time_score,'productivity',productivity_score,'decision_quality',decision_quality_score) as component_scores
from weighted;


-- ===== competition_round_normalized_productivity =====

create or replace view public.competition_team_live_metrics
with (security_invoker=true)
as
with order_metrics as (
 select team_id,count(*)::integer as total_orders,count(*) filter(where status='delivered')::integer as delivered_orders,
  coalesce(sum(quantity) filter(where status='delivered'),0)::numeric as delivered_units,
  coalesce(sum(quantity) filter(where status='delivered' and delivered_at<=due_at),0)::numeric as on_time_units,
  avg(extract(epoch from (delivered_at-created_at))/86400.0) filter(where status='delivered') as avg_delivery_days
 from public.competition_customer_orders group by team_id
), inventory_metrics as (
 select team_id,count(*)::integer as sku_count,count(*) filter(where quantity>reorder_level)::integer as healthy_skus,
  coalesce(sum(quantity),0)::numeric as inventory_units,coalesce(sum(quantity*unit_cost),0)::numeric as inventory_value,
  count(*) filter(where quantity<=reorder_level)::integer as low_stock_skus
 from public.competition_inventory group by team_id
), production_metrics as (
 select team_id,coalesce(sum(produced_quantity),0)::numeric as produced_units,count(*)::integer as production_runs
 from public.competition_production_runs where status='completed' group by team_id
), finance_metrics as (
 select team_id,coalesce(sum(amount) filter(where entry_type='revenue'),0)::numeric as revenue,
  coalesce(-sum(amount) filter(where entry_type in('purchase','production','transport')),0)::numeric as operating_cost
 from public.competition_ledger group by team_id
), decision_metrics as (
 select team_id,avg(score)::numeric as decision_quality,count(*)::integer as decision_count,
  count(*) filter(where score is not null)::integer as evaluated_decisions
 from public.competition_decisions group by team_id
), raw as (
 select t.id as team_id,t.competition_id,t.classroom_id,t.name as team_name,t.starting_capital,t.cash_balance,coalesce(clk.current_round,1) as current_round,
  t.production_capacity_units,ct.name as company_name,ct.scoring_weights,
  coalesce(o.total_orders,0) as total_orders,coalesce(o.delivered_orders,0) as delivered_orders,
  coalesce(o.delivered_units,0) as delivered_units,coalesce(o.on_time_units,0) as on_time_units,o.avg_delivery_days,
  coalesce(i.sku_count,0) as sku_count,coalesce(i.healthy_skus,0) as healthy_skus,coalesce(i.inventory_units,0) as inventory_units,
  coalesce(i.inventory_value,0) as inventory_value,coalesce(i.low_stock_skus,0) as low_stock_skus,
  coalesce(p.produced_units,0) as produced_units,coalesce(p.production_runs,0) as production_runs,
  coalesce(f.revenue,0) as revenue,coalesce(f.operating_cost,0) as operating_cost,
  coalesce(d.decision_count,0) as decision_count,coalesce(d.evaluated_decisions,0) as evaluated_decisions,
  d.decision_quality,coalesce((ct.operating_profile->>'baseline_lead_time_days')::numeric,7) as baseline_lead_time_days
 from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id
 left join order_metrics o on o.team_id=t.id left join inventory_metrics i on i.team_id=t.id
 left join production_metrics p on p.team_id=t.id left join finance_metrics f on f.team_id=t.id
 left join decision_metrics d on d.team_id=t.id left join public.competition_simulation_clock clk on clk.competition_id=t.competition_id
), scored as (
 select r.*,
  case when delivered_units>0 then round(100*on_time_units/delivered_units,2) end as service_score,
  case when starting_capital>0 then greatest(0,least(100,round(50+50*(cash_balance-starting_capital)/starting_capital,2))) end as cost_score,
  case when sku_count>0 then round(100.0*healthy_skus/sku_count,2) end as inventory_score,
  case when avg_delivery_days>0 then least(100,round(100*baseline_lead_time_days/avg_delivery_days,2)) end as lead_time_score,
  case when production_runs>0 and production_capacity_units>0 then least(100,round(100*produced_units/(production_capacity_units*greatest(1,current_round)),2)) end as productivity_score,
  round(decision_quality,2) as decision_quality_score
 from raw r
), weighted as (
 select s.*,
  (case when service_score is not null then coalesce((scoring_weights->>'service')::numeric,25) else 0 end+
   case when cost_score is not null then coalesce((scoring_weights->>'cost')::numeric,20) else 0 end+
   case when inventory_score is not null then coalesce((scoring_weights->>'inventory')::numeric,15) else 0 end+
   case when lead_time_score is not null then coalesce((scoring_weights->>'lead_time')::numeric,15) else 0 end+
   case when productivity_score is not null then coalesce((scoring_weights->>'productivity')::numeric,10) else 0 end+
   case when decision_quality_score is not null then coalesce((scoring_weights->>'decision_quality')::numeric,15) else 0 end) as available_weight,
  (coalesce(service_score,0)*coalesce((scoring_weights->>'service')::numeric,25)+
   coalesce(cost_score,0)*coalesce((scoring_weights->>'cost')::numeric,20)+
   coalesce(inventory_score,0)*coalesce((scoring_weights->>'inventory')::numeric,15)+
   coalesce(lead_time_score,0)*coalesce((scoring_weights->>'lead_time')::numeric,15)+
   coalesce(productivity_score,0)*coalesce((scoring_weights->>'productivity')::numeric,10)+
   coalesce(decision_quality_score,0)*coalesce((scoring_weights->>'decision_quality')::numeric,15)) as weighted_sum
 from scored s
)
select team_id,competition_id,classroom_id,team_name,company_name,starting_capital,cash_balance,total_orders,delivered_orders,
 delivered_units,on_time_units,avg_delivery_days,sku_count,healthy_skus,inventory_units,inventory_value,low_stock_skus,
 produced_units,production_runs,revenue,operating_cost,decision_count,evaluated_decisions,decision_quality,
 service_score,cost_score,inventory_score,lead_time_score,productivity_score,decision_quality_score,
 round(available_weight,2) as score_coverage_pct,
 case when delivered_orders>0 and production_runs>0 and evaluated_decisions>0 and available_weight>0
  then round(weighted_sum/available_weight,2) end as total_score,
 jsonb_build_object('service',service_score,'cost',cost_score,'inventory',inventory_score,
  'lead_time',lead_time_score,'productivity',productivity_score,'decision_quality',decision_quality_score) as component_scores,current_round
from weighted;


-- ===== competition_view_and_trigger_privilege_hardening =====

revoke all on public.competition_team_live_metrics from anon,authenticated;
grant select on public.competition_team_live_metrics to authenticated;
revoke all on function public.initialize_competition_team() from public,anon,authenticated;
revoke all on function public.initialize_competition_rounds() from public,anon,authenticated;


-- ===== competition_public_rankings =====

create or replace view public.competition_public_leaderboard
with (security_invoker=false)
as
select m.competition_id,m.team_id,m.team_name,m.company_name,m.total_score,m.score_coverage_pct,
 m.service_score,m.cost_score,m.inventory_score,m.lead_time_score,m.productivity_score,
 m.decision_quality_score,m.total_orders,m.delivered_orders,m.cash_balance,m.current_round
from public.competition_team_live_metrics m
join public.competitions c on c.id=m.competition_id
where c.status in('active','completed') and public.is_class_member(c.classroom_id);

create or replace view public.competition_individual_leaderboard
with (security_invoker=false)
as
select d.competition_id,d.student_id,p.full_name,t.id as team_id,t.name as team_name,
 count(*)::integer as decision_count,count(d.score)::integer as evaluated_decisions,
 round(avg(d.score),2) as average_score,max(d.score) as best_decision_score
from public.competition_decisions d
join public.profiles p on p.id=d.student_id
join public.competition_teams t on t.id=d.team_id
join public.competitions c on c.id=d.competition_id
where d.score is not null and c.status in('active','completed') and public.is_class_member(c.classroom_id)
group by d.competition_id,d.student_id,p.full_name,t.id,t.name;

revoke all on public.competition_public_leaderboard,public.competition_individual_leaderboard from anon,authenticated;
grant select on public.competition_public_leaderboard,public.competition_individual_leaderboard to authenticated;


-- ===== competition_public_leaderboard_paused_visibility =====

create or replace view public.competition_public_leaderboard
with (security_invoker=false)
as
select m.competition_id,m.team_id,m.team_name,m.company_name,m.total_score,m.score_coverage_pct,
 m.service_score,m.cost_score,m.inventory_score,m.lead_time_score,m.productivity_score,
 m.decision_quality_score,m.total_orders,m.delivered_orders,m.cash_balance,m.current_round
from public.competition_team_live_metrics m
join public.competitions c on c.id=m.competition_id
where c.status in('active','paused','completed') and public.is_class_member(c.classroom_id);
revoke all on public.competition_public_leaderboard from anon,authenticated;
grant select on public.competition_public_leaderboard to authenticated;


-- ===== competition_standard_role_task_pack =====

create or replace function public.create_competition_standard_task_pack(p_competition_id uuid)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_team record; v_count integer:=0; v_now timestamptz:=now();
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can create standard team tasks'; end if;
 if v_status not in('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then raise exception 'Tasks already exist. Add custom tasks instead of duplicating the standard pack'; end if;
 for v_team in select t.id,t.name,ct.name as company_name from public.competition_teams t
  join public.company_templates ct on ct.id=t.company_template_id where t.competition_id=p_competition_id
 loop
  if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='procurement')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='supplier')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='manufacturer')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='warehouse')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='transport') then
   raise exception 'Each team must have Procurement, Supplier, Manufacturer, Warehouse and Transport roles before generating the task pack';
  end if;
  insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_role,title,description,priority,due_at,created_by)
  values
  (p_competition_id,v_team.id,v_classroom_id,'procurement','Source critical raw materials',
   'Compare all supplier offers by unit cost, lead time and reliability. Select the best total-value option and place a purchase order for RM-001. Explain the trade-off between price, risk and continuity.', 'high',v_now+interval '1 day',(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'supplier','Negotiate supplier performance',
   'Review the supplier portfolio. Negotiate lead time, unit cost and reliability for one supplier. Record why the revised terms improve total supply-chain performance rather than only reducing price.', 'high',v_now+interval '1 day',(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'manufacturer','Plan and execute production',
   'Use available raw-material stock and production capacity to plan the right output for open customer orders. Complete a production run and explain how you avoided both shortages and excess production.', 'high',v_now+interval '2 days',(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'warehouse','Control receipts and inventory',
   'Check purchase-order availability before receiving stock. Record receipts accurately and monitor reorder points for RM-001 and FG-001. Explain how your inventory policy balances service and carrying cost.', 'normal',v_now+interval '2 days',(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'transport','Fulfil customer deliveries',
   'Prioritise open customer orders, dispatch only available finished goods, choose a suitable carrier and route, then confirm delivery when the simulated ETA is reached. Track on-time performance and transport cost.', 'high',v_now+interval '3 days',(select auth.uid()));
  v_count:=v_count+5;
 end loop;
 return v_count;
end; $$;
revoke all on function public.create_competition_standard_task_pack(uuid) from public,anon;
grant execute on function public.create_competition_standard_task_pack(uuid) to authenticated;


-- ===== competition_three_day_round_clock =====

create or replace function public.competition_advance_round(p_competition_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can advance the simulation'; end if;
 if v_status<>'active' then raise exception 'Competition must be active to advance a round'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if not found then raise exception 'Simulation clock has not been initialized'; end if;
 if v_clock.current_round>=v_clock.round_limit then raise exception 'Final round reached. Review scores and complete the competition'; end if;
 update public.competition_rounds set status='completed' where competition_id=p_competition_id and round_number=v_clock.current_round;
 update public.competition_simulation_clock set current_round=current_round+1,virtual_now=virtual_now+interval '3 days',updated_at=now()
 where competition_id=p_competition_id returning * into v_clock;
 update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select p_competition_id,t.id,t.classroom_id,(select auth.uid()),'teacher','round_advanced',
  'Simulation advanced to round '||v_clock.current_round,
  jsonb_build_object('round',v_clock.current_round,'virtual_now',v_clock.virtual_now,'days_advanced',3)
 from public.competition_teams t where t.competition_id=p_competition_id;
 return jsonb_build_object('current_round',v_clock.current_round,'round_limit',v_clock.round_limit,'virtual_now',v_clock.virtual_now,'days_advanced',3);
end; $$;
revoke all on function public.competition_advance_round(uuid) from public,anon;
grant execute on function public.competition_advance_round(uuid) to authenticated;


-- ===== competition_otd_counts_overdue_due_orders =====
create or replace view public.competition_team_live_metrics with (security_invoker=true) as
 WITH order_metrics AS (
         SELECT competition_customer_orders.team_id,
            count(*)::integer AS total_orders,
            count(*) FILTER (WHERE competition_customer_orders.status = 'delivered'::text)::integer AS delivered_orders,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text), 0::bigint)::numeric AS delivered_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text OR competition_customer_orders.due_at <= clk.virtual_now), 0::bigint)::numeric AS due_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text AND competition_customer_orders.delivered_at <= competition_customer_orders.due_at), 0::bigint)::numeric AS on_time_units,
            avg(EXTRACT(epoch FROM competition_customer_orders.delivered_at - competition_customer_orders.created_at) / 86400.0) FILTER (WHERE competition_customer_orders.status = 'delivered'::text) AS avg_delivery_days
           FROM competition_customer_orders
            JOIN competition_simulation_clock clk ON clk.competition_id = competition_customer_orders.competition_id
          GROUP BY competition_customer_orders.team_id
        ), inventory_metrics AS (
         SELECT competition_inventory.team_id,
            count(*)::integer AS sku_count,
            count(*) FILTER (WHERE competition_inventory.quantity > competition_inventory.reorder_level)::integer AS healthy_skus,
            COALESCE(sum(competition_inventory.quantity), 0::bigint)::numeric AS inventory_units,
            COALESCE(sum(competition_inventory.quantity::numeric * competition_inventory.unit_cost), 0::numeric) AS inventory_value,
            count(*) FILTER (WHERE competition_inventory.quantity <= competition_inventory.reorder_level)::integer AS low_stock_skus
           FROM competition_inventory
          GROUP BY competition_inventory.team_id
        ), production_metrics AS (
         SELECT competition_production_runs.team_id,
            COALESCE(sum(competition_production_runs.produced_quantity), 0::bigint)::numeric AS produced_units,
            count(*)::integer AS production_runs
           FROM competition_production_runs
          WHERE competition_production_runs.status = 'completed'::text
          GROUP BY competition_production_runs.team_id
        ), finance_metrics AS (
         SELECT competition_ledger.team_id,
            COALESCE(sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = 'revenue'::text), 0::numeric) AS revenue,
            COALESCE(- sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = ANY (ARRAY['purchase'::text, 'production'::text, 'transport'::text])), 0::numeric) AS operating_cost
           FROM competition_ledger
          GROUP BY competition_ledger.team_id
        ), decision_metrics AS (
         SELECT competition_decisions.team_id,
            avg(competition_decisions.score) AS decision_quality,
            count(*)::integer AS decision_count,
            count(*) FILTER (WHERE competition_decisions.score IS NOT NULL)::integer AS evaluated_decisions
           FROM competition_decisions
          GROUP BY competition_decisions.team_id
        ), raw AS (
         SELECT t.id AS team_id,
            t.competition_id,
            t.classroom_id,
            t.name AS team_name,
            t.starting_capital,
            t.cash_balance,
            COALESCE(clk.current_round, 1) AS current_round,
            t.production_capacity_units,
            ct.name AS company_name,
            ct.scoring_weights,
            COALESCE(o.total_orders, 0) AS total_orders,
            COALESCE(o.delivered_orders, 0) AS delivered_orders,
            COALESCE(o.delivered_units, 0::numeric) AS delivered_units,
            COALESCE(o.due_units, 0::numeric) AS due_units,
            COALESCE(o.on_time_units, 0::numeric) AS on_time_units,
            o.avg_delivery_days,
            COALESCE(i.sku_count, 0) AS sku_count,
            COALESCE(i.healthy_skus, 0) AS healthy_skus,
            COALESCE(i.inventory_units, 0::numeric) AS inventory_units,
            COALESCE(i.inventory_value, 0::numeric) AS inventory_value,
            COALESCE(i.low_stock_skus, 0) AS low_stock_skus,
            COALESCE(p.produced_units, 0::numeric) AS produced_units,
            COALESCE(p.production_runs, 0) AS production_runs,
            COALESCE(f.revenue, 0::numeric) AS revenue,
            COALESCE(f.operating_cost, 0::numeric) AS operating_cost,
            COALESCE(d.decision_count, 0) AS decision_count,
            COALESCE(d.evaluated_decisions, 0) AS evaluated_decisions,
            d.decision_quality,
            COALESCE((ct.operating_profile ->> 'baseline_lead_time_days'::text)::numeric, 7::numeric) AS baseline_lead_time_days
           FROM competition_teams t
             JOIN company_templates ct ON ct.id = t.company_template_id
             LEFT JOIN order_metrics o ON o.team_id = t.id
             LEFT JOIN inventory_metrics i ON i.team_id = t.id
             LEFT JOIN production_metrics p ON p.team_id = t.id
             LEFT JOIN finance_metrics f ON f.team_id = t.id
             LEFT JOIN decision_metrics d ON d.team_id = t.id
             LEFT JOIN competition_simulation_clock clk ON clk.competition_id = t.competition_id
        ), scored AS (
         SELECT r.team_id,
            r.competition_id,
            r.classroom_id,
            r.team_name,
            r.starting_capital,
            r.cash_balance,
            r.current_round,
            r.production_capacity_units,
            r.company_name,
            r.scoring_weights,
            r.total_orders,
            r.delivered_orders,
            r.delivered_units,
            r.due_units,
            r.on_time_units,
            r.avg_delivery_days,
            r.sku_count,
            r.healthy_skus,
            r.inventory_units,
            r.inventory_value,
            r.low_stock_skus,
            r.produced_units,
            r.production_runs,
            r.revenue,
            r.operating_cost,
            r.decision_count,
            r.evaluated_decisions,
            r.decision_quality,
            r.baseline_lead_time_days,
                CASE
                    WHEN r.due_units > 0::numeric THEN round(100::numeric * r.on_time_units / r.due_units, 2)
                    ELSE NULL::numeric
                END AS service_score,
                CASE
                    WHEN r.starting_capital > 0::numeric THEN GREATEST(0::numeric, LEAST(100::numeric, round(50::numeric + 50::numeric * (r.cash_balance - r.starting_capital) / r.starting_capital, 2)))
                    ELSE NULL::numeric
                END AS cost_score,
                CASE
                    WHEN r.sku_count > 0 THEN round(100.0 * r.healthy_skus::numeric / r.sku_count::numeric, 2)
                    ELSE NULL::numeric
                END AS inventory_score,
                CASE
                    WHEN r.avg_delivery_days > 0::numeric THEN LEAST(100::numeric, round(100::numeric * r.baseline_lead_time_days / r.avg_delivery_days, 2))
                    ELSE NULL::numeric
                END AS lead_time_score,
                CASE
                    WHEN r.production_runs > 0 AND r.production_capacity_units > 0 THEN LEAST(100::numeric, round(100::numeric * r.produced_units / (r.production_capacity_units * GREATEST(1, r.current_round))::numeric, 2))
                    ELSE NULL::numeric
                END AS productivity_score,
            round(r.decision_quality, 2) AS decision_quality_score
           FROM raw r
        ), weighted AS (
         SELECT s.team_id,
            s.competition_id,
            s.classroom_id,
            s.team_name,
            s.starting_capital,
            s.cash_balance,
            s.current_round,
            s.production_capacity_units,
            s.company_name,
            s.scoring_weights,
            s.total_orders,
            s.delivered_orders,
            s.delivered_units,
            s.due_units,
            s.on_time_units,
            s.avg_delivery_days,
            s.sku_count,
            s.healthy_skus,
            s.inventory_units,
            s.inventory_value,
            s.low_stock_skus,
            s.produced_units,
            s.production_runs,
            s.revenue,
            s.operating_cost,
            s.decision_count,
            s.evaluated_decisions,
            s.decision_quality,
            s.baseline_lead_time_days,
            s.service_score,
            s.cost_score,
            s.inventory_score,
            s.lead_time_score,
            s.productivity_score,
            s.decision_quality_score,
                CASE
                    WHEN s.service_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.cost_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.inventory_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.lead_time_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.productivity_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.decision_quality_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END AS available_weight,
            COALESCE(s.service_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric) + COALESCE(s.cost_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric) + COALESCE(s.inventory_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric) + COALESCE(s.lead_time_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric) + COALESCE(s.productivity_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric) + COALESCE(s.decision_quality_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric) AS weighted_sum
           FROM scored s
        )
 SELECT team_id,
    competition_id,
    classroom_id,
    team_name,
    company_name,
    starting_capital,
    cash_balance,
    total_orders,
    delivered_orders,
    delivered_units,
    on_time_units,
    avg_delivery_days,
    sku_count,
    healthy_skus,
    inventory_units,
    inventory_value,
    low_stock_skus,
    produced_units,
    production_runs,
    revenue,
    operating_cost,
    decision_count,
    evaluated_decisions,
    decision_quality,
    service_score,
    cost_score,
    inventory_score,
    lead_time_score,
    productivity_score,
    decision_quality_score,
    round(available_weight, 2) AS score_coverage_pct,
        CASE
            WHEN delivered_orders > 0 AND production_runs > 0 AND evaluated_decisions > 0 AND available_weight > 0::numeric THEN round(weighted_sum / available_weight, 2)
            ELSE NULL::numeric
        END AS total_score,
    jsonb_build_object('service', service_score, 'cost', cost_score, 'inventory', inventory_score, 'lead_time', lead_time_score, 'productivity', productivity_score, 'decision_quality', decision_quality_score) AS component_scores,
    current_round,
    due_units
   FROM weighted;;
 grant select on public.competition_team_live_metrics to authenticated;

-- ===== competition_active_state_enforcement =====
CREATE OR REPLACE FUNCTION public.competition_adjust_inventory(p_team_id uuid, p_sku text, p_delta integer, p_reason text DEFAULT 'Cycle count'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_qty integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['warehouse']) then raise exception 'Only the Warehouse Manager can adjust stock'; end if;
 if p_delta is null or p_delta=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 update public.competition_inventory set quantity=quantity+p_delta,updated_at=now()
 where team_id=p_team_id and sku=upper(trim(p_sku)) and quantity+p_delta>=0 returning quantity into v_qty;
 if not found then raise exception 'SKU not found or adjustment would make stock negative'; end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'warehouse','inventory_adjusted','Stock adjusted: '||p_sku,
 jsonb_build_object('delta',p_delta,'quantity_after',v_qty,'reason',left(coalesce(p_reason,''),300)));
 return v_qty;
end; $function$
;

CREATE OR REPLACE FUNCTION public.competition_complete_production(p_team_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_raw integer; v_fg integer; v_cost numeric; v_run uuid;
 v_profile jsonb; v_conversion numeric; v_product text; v_raw_sku text:='RM-001';
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['manufacturer']) then raise exception 'Only the assigned Production Manager can run production'; end if;
 if p_quantity is null or p_quantity not between 1 and v_team.production_capacity_units then raise exception 'Production quantity exceeds the per-round capacity'; end if;
 select ct.operating_profile into v_profile from public.company_templates ct join public.competition_teams t on t.company_template_id=ct.id where t.id=p_team_id;
 v_conversion:=coalesce((v_profile->>'conversion_cost_per_unit')::numeric,3);
 v_product:=coalesce(v_profile->>'product_name','Finished product');
 select quantity into v_raw from public.competition_inventory where team_id=p_team_id and sku=v_raw_sku for update;
 if not found or v_raw<p_quantity then raise exception 'Insufficient raw materials. Purchase and receive more first.'; end if;
 v_cost:=p_quantity*v_conversion;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash for production'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=p_team_id and sku=v_raw_sku;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,'finished_goods',p_quantity,60,0)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_fg;
 insert into public.competition_production_runs(competition_id,team_id,classroom_id,sku,item_name,planned_quantity,produced_quantity,raw_material_sku,conversion_cost_per_unit,status,completed_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,p_quantity,p_quantity,v_raw_sku,v_conversion,'completed',now())
 returning id into v_run;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'production',-v_cost,'Production conversion cost',v_run);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'manufacturer','production_completed','Produced '||p_quantity||' finished units',
 jsonb_build_object('production_run_id',v_run,'raw_material_remaining',v_raw-p_quantity,'finished_stock',v_fg,'cost',v_cost));
 return jsonb_build_object('production_run_id',v_run,'produced_quantity',p_quantity,'finished_stock',v_fg,'raw_material_remaining',v_raw-p_quantity,'cost',v_cost);
end; $function$
;

CREATE OR REPLACE FUNCTION public.competition_create_customer_order(p_team_id uuid, p_order_number text, p_sku text, p_item_name text, p_quantity integer, p_unit_price numeric, p_due_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['retailer','customer','operations']) then raise exception 'Only Customer/Retail Operations can create orders'; end if;
 if char_length(trim(coalesce(p_order_number,''))) not between 3 and 40 or char_length(trim(coalesce(p_sku,''))) not between 2 and 40 then raise exception 'Invalid order number or SKU'; end if;
 if char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 or p_quantity not between 1 and 100000 then raise exception 'Invalid item or quantity'; end if;
 if p_unit_price is null or p_unit_price<=0 or p_unit_price>1000000 or p_due_at is null or p_due_at<=now() then raise exception 'Invalid price or due date'; end if;
 insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,upper(trim(p_order_number)),upper(trim(p_sku)),trim(p_item_name),p_quantity,p_unit_price,p_due_at)
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Order number already exists for this team';
end; $function$
;

CREATE OR REPLACE FUNCTION public.competition_create_purchase_order(p_team_id uuid, p_supplier_id uuid, p_sku text, p_item_name text, p_quantity integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_supplier public.competition_suppliers%rowtype;
 v_clock public.competition_simulation_clock%rowtype; v_id uuid; v_po text; v_expected timestamptz; v_available timestamptz;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['procurement']) then raise exception 'Only the assigned Procurement Manager can create purchase orders'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id;
 if not found then raise exception 'Simulation clock not initialized'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id and team_id=p_team_id and active;
 if not found then raise exception 'Active supplier not found for this team'; end if;
 if p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Quantity must be 1-100,000'; end if;
 if char_length(trim(coalesce(p_sku,''))) not between 2 and 40 or char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 then raise exception 'Invalid SKU or item name'; end if;
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
declare v_ship public.competition_shipments%rowtype; v_order public.competition_customer_orders%rowtype; v_delivered integer; v_revenue numeric; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_ship.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_ship from public.competition_shipments where id=p_shipment_id for update;
 if not found then raise exception 'Shipment not found'; end if;
 if not public.is_competition_role(v_ship.competition_id,v_ship.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can confirm delivery'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_ship.competition_id;
 if v_ship.status='delivered' then raise exception 'Shipment is already delivered'; end if;
 if v_ship.status='cancelled' then raise exception 'Cancelled shipment cannot be delivered'; end if;
 if v_clock.virtual_now<v_ship.eta then raise exception 'Shipment is still in transit. Estimated arrival: %',v_ship.eta; end if;
 select * into v_order from public.competition_customer_orders where id=v_ship.order_id for update;
 update public.competition_shipments set status='delivered',delivered_at=v_clock.virtual_now where id=p_shipment_id;
 select coalesce(sum(quantity),0) into v_delivered from public.competition_shipments where order_id=v_ship.order_id and status='delivered';
 if v_delivered>=v_order.quantity then update public.competition_customer_orders set status='delivered',delivered_at=v_clock.virtual_now where id=v_order.id;
 else update public.competition_customer_orders set status='partially_shipped' where id=v_order.id; end if;
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
declare v_order public.competition_customer_orders%rowtype; v_stock integer; v_shipped integer; v_id uuid; v_cash numeric; v_clock public.competition_simulation_clock%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_order.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_order from public.competition_customer_orders where id=p_order_id for update;
 if not found then raise exception 'Customer order not found'; end if;
 if not public.is_competition_role(v_order.competition_id,v_order.team_id,array['transport']) then raise exception 'Only the assigned Transport Manager can dispatch shipments'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_order.competition_id;
 if p_quantity is null or p_quantity<1 or char_length(trim(coalesce(p_origin,'')))<2 or char_length(trim(coalesce(p_destination,'')))<2 or char_length(trim(coalesce(p_carrier,'')))<2 then raise exception 'Invalid shipment details'; end if;
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
declare v_po public.competition_purchase_orders%rowtype; v_team public.competition_teams%rowtype;
 v_clock public.competition_simulation_clock%rowtype; v_new integer; v_stock integer; v_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_po.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_po from public.competition_purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_competition_role(v_po.competition_id,v_po.team_id,array['warehouse']) then raise exception 'Only the assigned Warehouse Manager can receive stock'; end if;
 if v_po.status in('cancelled','received') then raise exception 'Purchase order cannot be received'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_po.competition_id;
 if v_clock.virtual_now<coalesce(v_po.available_at,v_po.expected_at) then
  raise exception 'Supplier delivery is not available yet. Expected date: %, reliability-adjusted availability: %',v_po.expected_at,coalesce(v_po.available_at,v_po.expected_at);
 end if;
 if p_quantity is null or p_quantity<1 or v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Invalid receipt quantity'; end if;
 v_cost:=p_quantity*v_po.unit_cost;
 select * into v_team from public.competition_teams where id=v_po.team_id for update;
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

CREATE OR REPLACE FUNCTION public.competition_update_supplier_terms(p_supplier_id uuid, p_lead_time_days integer, p_unit_cost numeric, p_reliability_score numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_supplier public.competition_suppliers%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_supplier.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id for update;
 if not found then raise exception 'Supplier not found'; end if;
 if not public.is_competition_role(v_supplier.competition_id,v_supplier.team_id,array['supplier','procurement']) then
  raise exception 'Only Supplier Relations or Procurement can negotiate supplier terms';
 end if;
 if p_lead_time_days is null or p_lead_time_days not between 1 and 90 then raise exception 'Lead time must be 1-90 days'; end if;
 if p_unit_cost is null or p_unit_cost<=0 or p_unit_cost>1000000 then raise exception 'Unit cost must be positive'; end if;
 if p_reliability_score is null or p_reliability_score not between 0 and 100 then raise exception 'Reliability must be 0-100'; end if;
 update public.competition_suppliers set lead_time_days=p_lead_time_days,unit_cost=p_unit_cost,reliability_score=p_reliability_score
 where id=p_supplier_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_supplier.competition_id,v_supplier.team_id,v_supplier.classroom_id,(select auth.uid()),'supplier','supplier_terms_updated',
  'Supplier terms negotiated: '||v_supplier.name,jsonb_build_object('supplier_id',p_supplier_id,'lead_time_days',p_lead_time_days,'unit_cost',p_unit_cost,'reliability',p_reliability_score));
 return true;
end; $function$
;

CREATE OR REPLACE FUNCTION public.submit_competition_task(p_task_id uuid, p_submission jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_task public.competition_tasks%rowtype; v_role text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_task.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
 if v_task.status not in ('pending','in_progress','rejected') then raise exception 'Task cannot be submitted in its current state'; end if;
 select operational_role into v_role from public.competition_team_members
 where competition_id=v_task.competition_id and team_id=v_task.team_id and student_id=(select auth.uid());
 if not found then raise exception 'You are not a member of this team'; end if;
 if v_task.assigned_to is not null and v_task.assigned_to <> (select auth.uid()) then raise exception 'This task is assigned to another student'; end if;
 if v_task.assigned_role is not null and v_task.assigned_role <> v_role then raise exception 'This task is assigned to another role'; end if;
 if jsonb_typeof(p_submission) <> 'object' then raise exception 'Submission must be a JSON object'; end if;
 if length(p_submission::text)>12000 then raise exception 'Submission is too large'; end if;
 update public.competition_tasks set status='submitted',submission=p_submission,submitted_at=now()
 where id=p_task_id;
 return p_task_id;
end;
$function$
;

-- ===== competition_final_score_snapshots =====
CREATE OR REPLACE FUNCTION public.set_competition_status(p_competition_id uuid, p_status text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_current text; v_team_count integer; v_member_count integer; v_round integer; v_round_limit integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_current from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can control this competition'; end if;
 if p_status not in ('active','paused','completed') then raise exception 'Invalid competition status'; end if;
 if p_status='active' and v_current='draft' then
  select count(*) into v_team_count from public.competition_teams where competition_id=p_competition_id;
  select count(*) into v_member_count from public.competition_team_members where competition_id=p_competition_id;
  if v_team_count<2 then raise exception 'Create at least two teams before starting'; end if;
  if v_member_count<2 then raise exception 'Assign students to teams before starting'; end if;
 end if;
 if v_current='completed' then raise exception 'Completed competitions cannot be reopened'; end if;
 if v_current='draft' and p_status not in ('active') then raise exception 'A draft competition can only be started'; end if;
 if p_status='completed' then
  select current_round,round_limit into v_round,v_round_limit from public.competition_simulation_clock where competition_id=p_competition_id for update;
  if v_round is null then raise exception 'Simulation clock is not initialized'; end if;
  if v_round<v_round_limit then raise exception 'Complete all simulation rounds before finalising the competition'; end if;
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
$function$
;

-- ===== competition_final_leaderboard_scores =====

create or replace view public.competition_public_leaderboard
with (security_invoker=false)
as
select m.competition_id,m.team_id,m.team_name,m.company_name,
 case when c.status='completed' then coalesce(s.total_score,0) else m.total_score end as total_score,
 case when c.status='completed' then coalesce((s.metrics->>'coverage_pct')::numeric,m.score_coverage_pct) else m.score_coverage_pct end as score_coverage_pct,
 m.service_score,m.cost_score,m.inventory_score,m.lead_time_score,m.productivity_score,
 m.decision_quality_score,m.total_orders,m.delivered_orders,m.cash_balance,m.current_round
from public.competition_team_live_metrics m
join public.competitions c on c.id=m.competition_id
left join public.competition_score_snapshots s on s.competition_id=m.competition_id
 and s.team_id=m.team_id and s.round_number=(select round_limit from public.competition_simulation_clock where competition_id=m.competition_id)
where c.status in('active','paused','completed') and public.is_class_member(c.classroom_id);
revoke all on public.competition_public_leaderboard from anon,authenticated;
grant select on public.competition_public_leaderboard to authenticated;


-- ===== competition_balanced_team_start_validation =====
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
 if (select count(*) from public.competition_teams where competition_id=p_competition_id)>=4 then raise exception 'A competition can have at most four teams'; end if;
 insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
 values(p_competition_id,v_classroom_id,p_company_template_id,trim(p_team_name))
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Team name already exists in this competition';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.set_competition_status(p_competition_id uuid, p_status text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_current text; v_team_count integer; v_member_count integer; v_class_member_count integer; v_min_team_size integer; v_max_team_size integer; v_round integer; v_round_limit integer;
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
 end if;
 if v_current='completed' then raise exception 'Completed competitions cannot be reopened'; end if;
 if v_current='draft' and p_status not in ('active') then raise exception 'A draft competition can only be started'; end if;
 if p_status='completed' then
  select current_round,round_limit into v_round,v_round_limit from public.competition_simulation_clock where competition_id=p_competition_id for update;
  if v_round is null then raise exception 'Simulation clock is not initialized'; end if;
  if v_round<v_round_limit then raise exception 'Complete all simulation rounds before finalising the competition'; end if;
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
$function$
;

-- ===== competition_task_round_deadlines =====

alter table public.competition_tasks
 add column if not exists due_round integer check(due_round is null or due_round between 1 and 20),
 add column if not exists submitted_round integer check(submitted_round is null or submitted_round between 1 and 20);
create index if not exists competition_tasks_round_idx on public.competition_tasks(competition_id,team_id,due_round,status);


-- ===== competition_task_round_deadline_workflow =====
CREATE OR REPLACE FUNCTION public.create_competition_standard_task_pack(p_competition_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_classroom_id uuid; v_status text; v_team record; v_count integer:=0; v_now timestamptz:=now();
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can create standard team tasks'; end if;
 if v_status not in('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then raise exception 'Tasks already exist. Add custom tasks instead of duplicating the standard pack'; end if;
 for v_team in select t.id,t.name,ct.name as company_name from public.competition_teams t
  join public.company_templates ct on ct.id=t.company_template_id where t.competition_id=p_competition_id
 loop
  if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='procurement')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='supplier')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='manufacturer')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='warehouse')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='transport') then
   raise exception 'Each team must have Procurement, Supplier, Manufacturer, Warehouse and Transport roles before generating the task pack';
  end if;
  insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_role,title,description,priority,due_at,due_round,created_by)
  values
  (p_competition_id,v_team.id,v_classroom_id,'procurement','Source critical raw materials',
   'Compare all supplier offers by unit cost, lead time and reliability. Select the best total-value option and place a purchase order for RM-001. Explain the trade-off between price, risk and continuity.', 'high',null,1,(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'supplier','Negotiate supplier performance',
   'Review the supplier portfolio. Negotiate lead time, unit cost and reliability for one supplier. Record why the revised terms improve total supply-chain performance rather than only reducing price.', 'high',null,1,(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'manufacturer','Plan and execute production',
   'Use available raw-material stock and production capacity to plan the right output for open customer orders. Complete a production run and explain how you avoided both shortages and excess production.', 'high',null,2,(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'warehouse','Control receipts and inventory',
   'Check purchase-order availability before receiving stock. Record receipts accurately and monitor reorder points for RM-001 and FG-001. Explain how your inventory policy balances service and carrying cost.', 'normal',null,2,(select auth.uid())),
  (p_competition_id,v_team.id,v_classroom_id,'transport','Fulfil customer deliveries',
   'Prioritise open customer orders, dispatch only available finished goods, choose a suitable carrier and route, then confirm delivery when the simulated ETA is reached. Track on-time performance and transport cost.', 'high',null,3,(select auth.uid()));
  v_count:=v_count+5;
 end loop;
 return v_count;
end; $function$
;
CREATE OR REPLACE FUNCTION public.submit_competition_task(p_task_id uuid, p_submission jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_task public.competition_tasks%rowtype; v_role text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=v_task.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
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
end;
$function$
;

-- ===== competition_task_performance_metrics =====

create or replace view public.competition_task_performance
with (security_invoker=true)
as
select t.competition_id,t.team_id,t.classroom_id,
 count(*) filter(where
  (t.due_round is not null and t.due_round<=coalesce(c.current_round,1))
  or (t.due_round is null and (t.due_at is null or t.due_at<=now()))
 )::integer as due_tasks,
 count(*) filter(where t.status='approved' and
  ((t.due_round is not null and t.due_round<=coalesce(c.current_round,1))
   or (t.due_round is null and (t.due_at is null or t.due_at<=now())))
 )::integer as approved_tasks,
 count(*) filter(where t.status='submitted')::integer as awaiting_review,
 count(*) filter(where t.submitted_round is not null and t.due_round is not null and t.submitted_round>t.due_round)::integer as late_submissions,
 case when count(*) filter(where
  (t.due_round is not null and t.due_round<=coalesce(c.current_round,1))
  or (t.due_round is null and (t.due_at is null or t.due_at<=now()))
 )>0 then round(100.0*count(*) filter(where t.status='approved' and
  ((t.due_round is not null and t.due_round<=coalesce(c.current_round,1))
   or (t.due_round is null and (t.due_at is null or t.due_at<=now()))))
  /count(*) filter(where
  (t.due_round is not null and t.due_round<=coalesce(c.current_round,1))
  or (t.due_round is null and (t.due_at is null or t.due_at<=now()))
 ),2) end as completion_pct
from public.competition_tasks t
left join public.competition_simulation_clock c on c.competition_id=t.competition_id
group by t.competition_id,t.team_id,t.classroom_id,c.current_round;

revoke all on public.competition_task_performance from anon,authenticated;
grant select on public.competition_task_performance to authenticated;


-- ===== competition_inventory_holding_costs =====

update public.company_templates set operating_profile=operating_profile||'{"holding_cost_rate":0.010}'::jsonb where slug='lean-automotive';
update public.company_templates set operating_profile=operating_profile||'{"holding_cost_rate":0.008}'::jsonb where slug='omnichannel-retail';
update public.company_templates set operating_profile=operating_profile||'{"holding_cost_rate":0.015}'::jsonb where slug='flatpack-global';
update public.company_templates set operating_profile=operating_profile||'{"holding_cost_rate":0.012}'::jsonb where slug='beverage-fast-moving';

create or replace function public.competition_advance_round(p_competition_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_clock public.competition_simulation_clock%rowtype;
 v_team record; v_inventory_value numeric; v_rate numeric; v_holding_cost numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can advance the simulation'; end if;
 if v_status<>'active' then raise exception 'Competition must be active to advance a round'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if not found then raise exception 'Simulation clock has not been initialized'; end if;
 if v_clock.current_round>=v_clock.round_limit then raise exception 'Final round reached. Review scores and complete the competition'; end if;
 for v_team in
  select t.id,t.classroom_id,ct.operating_profile
  from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id
  where t.competition_id=p_competition_id
 loop
  select coalesce(sum(quantity*unit_cost),0) into v_inventory_value
  from public.competition_inventory where team_id=v_team.id;
  v_rate:=coalesce((v_team.operating_profile->>'holding_cost_rate')::numeric,0.01);
  v_holding_cost:=round(v_inventory_value*v_rate,2);
  if v_holding_cost>0 then
   update public.competition_teams set cash_balance=cash_balance-v_holding_cost where id=v_team.id;
   insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description)
   values(p_competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'adjustment',-v_holding_cost,
    'Inventory holding cost for round '||v_clock.current_round);
   insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
   values(p_competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'teacher','inventory_holding_cost',
    'Inventory carrying cost charged for round '||v_clock.current_round,
    jsonb_build_object('inventory_value',v_inventory_value,'rate',v_rate,'cost',v_holding_cost));
  end if;
 end loop;
 update public.competition_rounds set status='completed' where competition_id=p_competition_id and round_number=v_clock.current_round;
 update public.competition_simulation_clock set current_round=current_round+1,virtual_now=virtual_now+interval '3 days',updated_at=now()
 where competition_id=p_competition_id returning * into v_clock;
 update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select p_competition_id,t.id,t.classroom_id,(select auth.uid()),'teacher','round_advanced',
  'Simulation advanced to round '||v_clock.current_round,
  jsonb_build_object('round',v_clock.current_round,'virtual_now',v_clock.virtual_now,'days_advanced',3)
 from public.competition_teams t where t.competition_id=p_competition_id;
 return jsonb_build_object('current_round',v_clock.current_round,'round_limit',v_clock.round_limit,
  'virtual_now',v_clock.virtual_now,'days_advanced',3,'inventory_holding_cost_applied',true);
end; $$;
revoke all on function public.competition_advance_round(uuid) from public,anon;
grant execute on function public.competition_advance_round(uuid) to authenticated;


-- ===== competition_carrying_cost_in_profit_metric =====
create or replace view public.competition_team_live_metrics with (security_invoker=true) as
 WITH order_metrics AS (
         SELECT competition_customer_orders.team_id,
            count(*)::integer AS total_orders,
            count(*) FILTER (WHERE competition_customer_orders.status = 'delivered'::text)::integer AS delivered_orders,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text), 0::bigint)::numeric AS delivered_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text OR competition_customer_orders.due_at <= clk.virtual_now), 0::bigint)::numeric AS due_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text AND competition_customer_orders.delivered_at <= competition_customer_orders.due_at), 0::bigint)::numeric AS on_time_units,
            avg(EXTRACT(epoch FROM competition_customer_orders.delivered_at - competition_customer_orders.created_at) / 86400.0) FILTER (WHERE competition_customer_orders.status = 'delivered'::text) AS avg_delivery_days
           FROM competition_customer_orders
             JOIN competition_simulation_clock clk ON clk.competition_id = competition_customer_orders.competition_id
          GROUP BY competition_customer_orders.team_id
        ), inventory_metrics AS (
         SELECT competition_inventory.team_id,
            count(*)::integer AS sku_count,
            count(*) FILTER (WHERE competition_inventory.quantity > competition_inventory.reorder_level)::integer AS healthy_skus,
            COALESCE(sum(competition_inventory.quantity), 0::bigint)::numeric AS inventory_units,
            COALESCE(sum(competition_inventory.quantity::numeric * competition_inventory.unit_cost), 0::numeric) AS inventory_value,
            count(*) FILTER (WHERE competition_inventory.quantity <= competition_inventory.reorder_level)::integer AS low_stock_skus
           FROM competition_inventory
          GROUP BY competition_inventory.team_id
        ), production_metrics AS (
         SELECT competition_production_runs.team_id,
            COALESCE(sum(competition_production_runs.produced_quantity), 0::bigint)::numeric AS produced_units,
            count(*)::integer AS production_runs
           FROM competition_production_runs
          WHERE competition_production_runs.status = 'completed'::text
          GROUP BY competition_production_runs.team_id
        ), finance_metrics AS (
         SELECT competition_ledger.team_id,
            COALESCE(sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = 'revenue'::text), 0::numeric) AS revenue,
            COALESCE(- sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = ANY (ARRAY['purchase'::text, 'production'::text, 'transport'::text, 'adjustment'::text])), 0::numeric) AS operating_cost
           FROM competition_ledger
          GROUP BY competition_ledger.team_id
        ), decision_metrics AS (
         SELECT competition_decisions.team_id,
            avg(competition_decisions.score) AS decision_quality,
            count(*)::integer AS decision_count,
            count(*) FILTER (WHERE competition_decisions.score IS NOT NULL)::integer AS evaluated_decisions
           FROM competition_decisions
          GROUP BY competition_decisions.team_id
        ), raw AS (
         SELECT t.id AS team_id,
            t.competition_id,
            t.classroom_id,
            t.name AS team_name,
            t.starting_capital,
            t.cash_balance,
            COALESCE(clk.current_round, 1) AS current_round,
            t.production_capacity_units,
            ct.name AS company_name,
            ct.scoring_weights,
            COALESCE(o.total_orders, 0) AS total_orders,
            COALESCE(o.delivered_orders, 0) AS delivered_orders,
            COALESCE(o.delivered_units, 0::numeric) AS delivered_units,
            COALESCE(o.due_units, 0::numeric) AS due_units,
            COALESCE(o.on_time_units, 0::numeric) AS on_time_units,
            o.avg_delivery_days,
            COALESCE(i.sku_count, 0) AS sku_count,
            COALESCE(i.healthy_skus, 0) AS healthy_skus,
            COALESCE(i.inventory_units, 0::numeric) AS inventory_units,
            COALESCE(i.inventory_value, 0::numeric) AS inventory_value,
            COALESCE(i.low_stock_skus, 0) AS low_stock_skus,
            COALESCE(p.produced_units, 0::numeric) AS produced_units,
            COALESCE(p.production_runs, 0) AS production_runs,
            COALESCE(f.revenue, 0::numeric) AS revenue,
            COALESCE(f.operating_cost, 0::numeric) AS operating_cost,
            COALESCE(d.decision_count, 0) AS decision_count,
            COALESCE(d.evaluated_decisions, 0) AS evaluated_decisions,
            d.decision_quality,
            COALESCE((ct.operating_profile ->> 'baseline_lead_time_days'::text)::numeric, 7::numeric) AS baseline_lead_time_days
           FROM competition_teams t
             JOIN company_templates ct ON ct.id = t.company_template_id
             LEFT JOIN order_metrics o ON o.team_id = t.id
             LEFT JOIN inventory_metrics i ON i.team_id = t.id
             LEFT JOIN production_metrics p ON p.team_id = t.id
             LEFT JOIN finance_metrics f ON f.team_id = t.id
             LEFT JOIN decision_metrics d ON d.team_id = t.id
             LEFT JOIN competition_simulation_clock clk ON clk.competition_id = t.competition_id
        ), scored AS (
         SELECT r.team_id,
            r.competition_id,
            r.classroom_id,
            r.team_name,
            r.starting_capital,
            r.cash_balance,
            r.current_round,
            r.production_capacity_units,
            r.company_name,
            r.scoring_weights,
            r.total_orders,
            r.delivered_orders,
            r.delivered_units,
            r.due_units,
            r.on_time_units,
            r.avg_delivery_days,
            r.sku_count,
            r.healthy_skus,
            r.inventory_units,
            r.inventory_value,
            r.low_stock_skus,
            r.produced_units,
            r.production_runs,
            r.revenue,
            r.operating_cost,
            r.decision_count,
            r.evaluated_decisions,
            r.decision_quality,
            r.baseline_lead_time_days,
                CASE
                    WHEN r.due_units > 0::numeric THEN round(100::numeric * r.on_time_units / r.due_units, 2)
                    ELSE NULL::numeric
                END AS service_score,
                CASE
                    WHEN r.starting_capital > 0::numeric THEN GREATEST(0::numeric, LEAST(100::numeric, round(50::numeric + 50::numeric * (r.cash_balance - r.starting_capital) / r.starting_capital, 2)))
                    ELSE NULL::numeric
                END AS cost_score,
                CASE
                    WHEN r.sku_count > 0 THEN round(100.0 * r.healthy_skus::numeric / r.sku_count::numeric, 2)
                    ELSE NULL::numeric
                END AS inventory_score,
                CASE
                    WHEN r.avg_delivery_days > 0::numeric THEN LEAST(100::numeric, round(100::numeric * r.baseline_lead_time_days / r.avg_delivery_days, 2))
                    ELSE NULL::numeric
                END AS lead_time_score,
                CASE
                    WHEN r.production_runs > 0 AND r.production_capacity_units > 0 THEN LEAST(100::numeric, round(100::numeric * r.produced_units / (r.production_capacity_units * GREATEST(1, r.current_round))::numeric, 2))
                    ELSE NULL::numeric
                END AS productivity_score,
            round(r.decision_quality, 2) AS decision_quality_score
           FROM raw r
        ), weighted AS (
         SELECT s.team_id,
            s.competition_id,
            s.classroom_id,
            s.team_name,
            s.starting_capital,
            s.cash_balance,
            s.current_round,
            s.production_capacity_units,
            s.company_name,
            s.scoring_weights,
            s.total_orders,
            s.delivered_orders,
            s.delivered_units,
            s.due_units,
            s.on_time_units,
            s.avg_delivery_days,
            s.sku_count,
            s.healthy_skus,
            s.inventory_units,
            s.inventory_value,
            s.low_stock_skus,
            s.produced_units,
            s.production_runs,
            s.revenue,
            s.operating_cost,
            s.decision_count,
            s.evaluated_decisions,
            s.decision_quality,
            s.baseline_lead_time_days,
            s.service_score,
            s.cost_score,
            s.inventory_score,
            s.lead_time_score,
            s.productivity_score,
            s.decision_quality_score,
                CASE
                    WHEN s.service_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.cost_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.inventory_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.lead_time_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.productivity_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.decision_quality_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END AS available_weight,
            COALESCE(s.service_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric) + COALESCE(s.cost_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric) + COALESCE(s.inventory_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric) + COALESCE(s.lead_time_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric) + COALESCE(s.productivity_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric) + COALESCE(s.decision_quality_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric) AS weighted_sum
           FROM scored s
        )
 SELECT team_id,
    competition_id,
    classroom_id,
    team_name,
    company_name,
    starting_capital,
    cash_balance,
    total_orders,
    delivered_orders,
    delivered_units,
    on_time_units,
    avg_delivery_days,
    sku_count,
    healthy_skus,
    inventory_units,
    inventory_value,
    low_stock_skus,
    produced_units,
    production_runs,
    revenue,
    operating_cost,
    decision_count,
    evaluated_decisions,
    decision_quality,
    service_score,
    cost_score,
    inventory_score,
    lead_time_score,
    productivity_score,
    decision_quality_score,
    round(available_weight, 2) AS score_coverage_pct,
        CASE
            WHEN delivered_orders > 0 AND production_runs > 0 AND evaluated_decisions > 0 AND available_weight > 0::numeric THEN round(weighted_sum / available_weight, 2)
            ELSE NULL::numeric
        END AS total_score,
    jsonb_build_object('service', service_score, 'cost', cost_score, 'inventory', inventory_score, 'lead_time', lead_time_score, 'productivity', productivity_score, 'decision_quality', decision_quality_score) AS component_scores,
    current_round,
    due_units
   FROM weighted;;
grant select on public.competition_team_live_metrics to authenticated;

-- ===== competition_individual_leaderboard_privacy =====

drop view public.competition_individual_leaderboard;
create view public.competition_individual_leaderboard
with (security_invoker=false)
as
select d.competition_id,p.full_name,t.name as team_name,
 count(*)::integer as decision_count,count(d.score)::integer as evaluated_decisions,
 round(avg(d.score),2) as average_score,max(d.score) as best_decision_score
from public.competition_decisions d
join public.profiles p on p.id=d.student_id
join public.competition_teams t on t.id=d.team_id
join public.competitions c on c.id=d.competition_id
where d.score is not null and c.status in('active','paused','completed') and public.is_class_member(c.classroom_id)
group by d.competition_id,d.student_id,p.full_name,t.id,t.name;
revoke all on public.competition_individual_leaderboard from anon,authenticated;
grant select on public.competition_individual_leaderboard to authenticated;


-- ===== competition_production_inventory_costing =====

create or replace function public.competition_complete_production(p_team_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_raw integer; v_raw_unit_cost numeric; v_fg integer; v_cost numeric; v_run uuid;
 v_profile jsonb; v_conversion numeric; v_product text; v_raw_sku text:='RM-001';
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not exists(select 1 from public.competitions where id=(select competition_id from public.competition_teams where id=p_team_id) and status='active') then raise exception 'Competition is not active'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['manufacturer']) then raise exception 'Only the assigned Production Manager can run production'; end if;
 if p_quantity is null or p_quantity not between 1 and v_team.production_capacity_units then raise exception 'Production quantity exceeds the per-round capacity'; end if;
 select ct.operating_profile into v_profile from public.company_templates ct join public.competition_teams t on t.company_template_id=ct.id where t.id=p_team_id;
 v_conversion:=coalesce((v_profile->>'conversion_cost_per_unit')::numeric,3);
 v_product:=coalesce(v_profile->>'product_name','Finished product');
 select quantity,unit_cost into v_raw,v_raw_unit_cost from public.competition_inventory where team_id=p_team_id and sku=v_raw_sku for update;
 if not found or v_raw<p_quantity then raise exception 'Insufficient raw materials. Purchase and receive more first.'; end if;
 v_cost:=p_quantity*v_conversion;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash for production'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now() where team_id=p_team_id and sku=v_raw_sku;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,'finished_goods',p_quantity,60,v_raw_unit_cost+v_conversion)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,
  unit_cost=excluded.unit_cost,updated_at=now()
 returning quantity into v_fg;
 insert into public.competition_production_runs(competition_id,team_id,classroom_id,sku,item_name,planned_quantity,produced_quantity,raw_material_sku,conversion_cost_per_unit,status,completed_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,p_quantity,p_quantity,v_raw_sku,v_conversion,'completed',now())
 returning id into v_run;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'production',-v_cost,'Production conversion cost',v_run);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'manufacturer','production_completed','Produced '||p_quantity||' finished units',
 jsonb_build_object('production_run_id',v_run,'raw_material_remaining',v_raw-p_quantity,'finished_stock',v_fg,'cost',v_cost,'finished_unit_cost',v_raw_unit_cost+v_conversion));
 return jsonb_build_object('production_run_id',v_run,'produced_quantity',p_quantity,'finished_stock',v_fg,'raw_material_remaining',v_raw-p_quantity,'cost',v_cost);
end; $$;
revoke all on function public.competition_complete_production(uuid,integer) from public,anon;
grant execute on function public.competition_complete_production(uuid,integer) to authenticated;


-- ===== repair_competition_rpc_row_loading =====

-- Repair competition RPCs that checked an uninitialised row variable
-- before loading the requested team/order/shipment/task.
create or replace function public.competition_create_purchase_order(
 p_team_id uuid,p_supplier_id uuid,p_sku text,p_item_name text,p_quantity integer
) returns uuid language plpgsql security definer set search_path=''
as $$
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
end; $$;

create or replace function public.competition_receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=''
as $$
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
end; $$;

create or replace function public.competition_dispatch_shipment(
 p_order_id uuid,p_quantity integer,p_origin text,p_destination text,p_carrier text,p_transport_cost numeric default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
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
end; $$;

create or replace function public.competition_deliver_shipment(p_shipment_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
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
end; $$;

create or replace function public.submit_competition_task(p_task_id uuid,p_submission jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
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
end; $$;

-- Preserve the original least-privilege RPC grants.
revoke all on function public.competition_create_purchase_order(uuid,uuid,text,text,integer) from public,anon;
grant execute on function public.competition_create_purchase_order(uuid,uuid,text,text,integer) to authenticated;
revoke all on function public.competition_receive_purchase_order(uuid,integer) from public,anon;
grant execute on function public.competition_receive_purchase_order(uuid,integer) to authenticated;
revoke all on function public.competition_dispatch_shipment(uuid,integer,text,text,text,numeric) from public,anon;
grant execute on function public.competition_dispatch_shipment(uuid,integer,text,text,text,numeric) to authenticated;
revoke all on function public.competition_deliver_shipment(uuid) from public,anon;
grant execute on function public.competition_deliver_shipment(uuid) to authenticated;
revoke all on function public.submit_competition_task(uuid,jsonb) from public,anon;
grant execute on function public.submit_competition_task(uuid,jsonb) to authenticated;


-- ===== make_competition_leaderboards_security_invoker =====
alter view public.competition_public_leaderboard set (security_invoker = true);
alter view public.competition_individual_leaderboard set (security_invoker = true);

-- ===== repair_competition_inventory_order_supplier_rpcs =====

-- Repair three additional competition RPCs with the same row-load ordering defect.
create or replace function public.competition_adjust_inventory(p_team_id uuid,p_sku text,p_delta integer,p_reason text default 'Cycle count')
returns integer language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_qty integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['warehouse']) then raise exception 'Only the Warehouse Manager can adjust stock'; end if;
 if p_delta is null or p_delta=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 update public.competition_inventory set quantity=quantity+p_delta,updated_at=now()
 where team_id=p_team_id and sku=upper(trim(p_sku)) and quantity+p_delta>=0 returning quantity into v_qty;
 if not found then raise exception 'SKU not found or adjustment would make stock negative'; end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'warehouse','inventory_adjusted','Stock adjusted: '||p_sku,
 jsonb_build_object('delta',p_delta,'quantity_after',v_qty,'reason',left(coalesce(p_reason,''),300)));
 return v_qty;
end; $$;

create or replace function public.competition_create_customer_order(
 p_team_id uuid,p_order_number text,p_sku text,p_item_name text,p_quantity integer,p_unit_price numeric,p_due_at timestamptz
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['retailer','customer','operations']) then
  raise exception 'Only Customer/Retail Operations can create orders';
 end if;
 if char_length(trim(coalesce(p_order_number,''))) not between 3 and 40 or char_length(trim(coalesce(p_sku,''))) not between 2 and 40 then raise exception 'Invalid order number or SKU'; end if;
 if char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 or p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Invalid item or quantity'; end if;
 if p_unit_price is null or p_unit_price<=0 or p_unit_price>1000000 or p_due_at is null or p_due_at<=now() then raise exception 'Invalid price or due date'; end if;
 insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,upper(trim(p_order_number)),upper(trim(p_sku)),trim(p_item_name),p_quantity,p_unit_price,p_due_at)
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Order number already exists for this team';
end; $$;

create or replace function public.competition_update_supplier_terms(
 p_supplier_id uuid,p_lead_time_days integer,p_unit_cost numeric,p_reliability_score numeric
) returns boolean language plpgsql security definer set search_path=''
as $$
declare v_supplier public.competition_suppliers%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id for update;
 if not found then raise exception 'Supplier not found'; end if;
 if not exists(select 1 from public.competitions where id=v_supplier.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_supplier.competition_id,v_supplier.team_id,array['supplier','procurement']) then
  raise exception 'Only Supplier Relations or Procurement can negotiate supplier terms';
 end if;
 if p_lead_time_days is null or p_lead_time_days not between 1 and 90 then raise exception 'Lead time must be 1-90 days'; end if;
 if p_unit_cost is null or p_unit_cost<=0 or p_unit_cost>1000000 then raise exception 'Unit cost must be positive'; end if;
 if p_reliability_score is null or p_reliability_score not between 0 and 100 then raise exception 'Reliability must be 0-100'; end if;
 update public.competition_suppliers set lead_time_days=p_lead_time_days,unit_cost=p_unit_cost,reliability_score=p_reliability_score where id=p_supplier_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_supplier.competition_id,v_supplier.team_id,v_supplier.classroom_id,(select auth.uid()),'supplier','supplier_terms_updated',
  'Supplier terms negotiated: '||v_supplier.name,jsonb_build_object('supplier_id',p_supplier_id,'lead_time_days',p_lead_time_days,'unit_cost',p_unit_cost,'reliability',p_reliability_score));
 return true;
end; $$;

revoke all on function public.competition_adjust_inventory(uuid,text,integer,text) from public,anon;
grant execute on function public.competition_adjust_inventory(uuid,text,integer,text) to authenticated;
revoke all on function public.competition_create_customer_order(uuid,text,text,text,integer,numeric,timestamptz) from public,anon;
grant execute on function public.competition_create_customer_order(uuid,text,text,text,integer,numeric,timestamptz) to authenticated;
revoke all on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) from public,anon;
grant execute on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) to authenticated;


-- ===== fix_balanced_competition_team_array_assignment =====

create or replace function public.create_balanced_competition_teams(p_competition_id uuid,p_team_count integer default 4)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_id uuid; v_team_no integer; v_role_no integer;
 v_roles text[]:=array['procurement','supplier','manufacturer','warehouse','transport'];
 v_idx integer:=0; v_student_assignments integer:=0;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then raise exception 'Teams already exist; use manual assignment instead'; end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_student_count<p_team_count then raise exception 'Not enough students to create balanced teams'; end if;
 for v_template in
  select id,name from public.company_templates where active order by
   case slug when 'lean-automotive' then 1 when 'omnichannel-retail' then 2 when 'flatpack-global' then 3 when 'beverage-fast-moving' then 4 else 5 end
  limit p_team_count
 loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Team '||v_created||' · '||v_template.name)
  returning id into v_team_id;
  v_team_ids:=array_append(v_team_ids,v_team_id);
  v_team_names:=array_append(v_team_names,'Team '||v_created||' · '||v_template.name);
 end loop;
 if v_created<>p_team_count then raise exception 'Not enough active company templates'; end if;
 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id order by joined_at,student_id
 loop
  v_idx:=v_member.rn;
  v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,'student_count',v_student_assignments,'team_names',to_jsonb(v_team_names));
end; $$;
revoke all on function public.create_balanced_competition_teams(uuid,integer) from public,anon;
grant execute on function public.create_balanced_competition_teams(uuid,integer) to authenticated;


-- ===== competition_safe_public_leaderboard_rpcs =====

create or replace function public.get_competition_leaderboard(p_competition_id uuid)
returns table(
 team_name text,company_name text,total_score numeric,score_coverage_pct numeric,
 service_score numeric,cost_score numeric,inventory_score numeric,lead_time_score numeric,
 productivity_score numeric,decision_quality_score numeric,total_orders integer,delivered_orders integer,
 cash_balance numeric,current_round integer
)
language plpgsql stable security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_member(v_classroom_id) then raise exception 'You are not a member of this classroom'; end if;
 if v_status not in('active','paused','completed') then raise exception 'Competition results are not public yet'; end if;
 return query
 select m.team_name,m.company_name,
  case when v_status='completed' then coalesce(s.total_score,0) else m.total_score end,
  case when v_status='completed' then coalesce((s.metrics->>'coverage_pct')::numeric,m.score_coverage_pct) else m.score_coverage_pct end,
  m.service_score,m.cost_score,m.inventory_score,m.lead_time_score,m.productivity_score,m.decision_quality_score,
  m.total_orders,m.delivered_orders,m.cash_balance,m.current_round
 from public.competition_team_live_metrics m
 left join public.competition_simulation_clock clk on clk.competition_id=m.competition_id
 left join public.competition_score_snapshots s on s.competition_id=m.competition_id
  and s.team_id=m.team_id and s.round_number=clk.round_limit
 where m.competition_id=p_competition_id
 order by case when v_status='completed' then coalesce(s.total_score,0) else m.total_score end desc nulls last,m.team_name;
end; $$;

create or replace function public.get_competition_individual_leaderboard(p_competition_id uuid)
returns table(
 full_name text,team_name text,decision_count integer,evaluated_decisions integer,
 average_score numeric,best_decision_score numeric
)
language plpgsql stable security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_member(v_classroom_id) then raise exception 'You are not a member of this classroom'; end if;
 if v_status not in('active','paused','completed') then raise exception 'Competition results are not public yet'; end if;
 return query
 select p.full_name,t.name,count(*)::integer,count(d.score)::integer,round(avg(d.score),2),max(d.score)
 from public.competition_decisions d
 join public.profiles p on p.id=d.student_id
 join public.competition_teams t on t.id=d.team_id
 where d.competition_id=p_competition_id and d.score is not null
 group by d.student_id,p.full_name,t.id,t.name
 order by round(avg(d.score),2) desc,count(*) desc,p.full_name;
end; $$;

revoke all on function public.get_competition_leaderboard(uuid) from public,anon;
grant execute on function public.get_competition_leaderboard(uuid) to authenticated;
revoke all on function public.get_competition_individual_leaderboard(uuid) from public,anon;
grant execute on function public.get_competition_individual_leaderboard(uuid) to authenticated;
