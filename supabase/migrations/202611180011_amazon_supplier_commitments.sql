
create table if not exists public.amazon_case_supplier_commitments (
 id uuid primary key default gen_random_uuid(),
 competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 supplier_code text not null check (supplier_code in ('SUP-A','SUP-B','SUP-C')),
 sku text not null references public.amazon_case_skus(sku),
 committed_quantity integer not null check (committed_quantity>0),
 expected_arrival_day integer not null check (expected_arrival_day between 1 and 30),
 commitment_status text not null check (commitment_status in ('confirmed','at_risk','escalated')),
 note text not null,
 created_by uuid not null,
 created_at timestamptz not null default now()
);
alter table public.amazon_case_supplier_commitments enable row level security;

create or replace function public.amazon_record_supplier_commitment(
 p_team_id uuid,p_supplier_code text,p_sku text,p_quantity integer,p_expected_arrival_day integer,p_status text,p_note text
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_clock public.competition_simulation_clock%rowtype;
 v_offer public.amazon_case_supplier_offers%rowtype; v_id uuid; v_min_day integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not public.is_competition_role(v_team.competition_id,p_team_id,array['supplier']) then raise exception 'Only Supplier Relations Manager can record supplier commitments'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 select * into v_clock from public.competition_simulation_clock where competition_id=v_team.competition_id;
 select * into v_offer from public.amazon_case_supplier_offers where team_id=p_team_id and supplier_code=p_supplier_code and sku=upper(p_sku);
 if not found then raise exception 'Supplier offer for this SKU was not found'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>v_offer.max_capacity then raise exception 'Commitment quantity exceeds supplier SKU capacity'; end if;
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
end; $$;
grant execute on function public.amazon_record_supplier_commitment(uuid,text,text,integer,integer,text,text) to authenticated;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_get_case_data(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '  ''fulfilment'',(select coalesce(jsonb_agg(jsonb_build_object(''order_id'',f.order_id,''ready_quantity'',f.ready_quantity,''updated_round'',f.updated_round)),''[]''::jsonb) from public.amazon_case_fulfillment f where f.team_id=p_team_id),',
  '  ''fulfilment'',(select coalesce(jsonb_agg(jsonb_build_object(''order_id'',f.order_id,''ready_quantity'',f.ready_quantity,''updated_round'',f.updated_round)),''[]''::jsonb) from public.amazon_case_fulfillment f where f.team_id=p_team_id),
  ''commitments'',(select coalesce(jsonb_agg(to_jsonb(sc) order by sc.created_at desc),''[]''::jsonb) from public.amazon_case_supplier_commitments sc where sc.team_id=p_team_id),');
 execute v_def;
end $migration$;
