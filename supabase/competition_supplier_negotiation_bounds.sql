-- Freeze each supplier's starting terms and constrain negotiated changes to bounded trade-offs.
alter table public.competition_suppliers
 add column if not exists base_lead_time_days integer,
 add column if not exists base_unit_cost numeric(12,2),
 add column if not exists base_reliability_score numeric(5,2);
update public.competition_suppliers set
 base_lead_time_days=coalesce(base_lead_time_days,lead_time_days),
 base_unit_cost=coalesce(base_unit_cost,unit_cost),
 base_reliability_score=coalesce(base_reliability_score,reliability_score);
alter table public.competition_suppliers alter column base_lead_time_days set not null,
 alter column base_unit_cost set not null,alter column base_reliability_score set not null;
alter table public.competition_suppliers add constraint competition_suppliers_base_lead_time_check check(base_lead_time_days between 1 and 90),
 add constraint competition_suppliers_base_unit_cost_check check(base_unit_cost>0),
 add constraint competition_suppliers_base_reliability_check check(base_reliability_score between 0 and 100);

CREATE OR REPLACE FUNCTION public.preserve_competition_supplier_baseline()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if tg_op='INSERT' then
  new.base_lead_time_days:=coalesce(new.base_lead_time_days,new.lead_time_days);
  new.base_unit_cost:=coalesce(new.base_unit_cost,new.unit_cost);
  new.base_reliability_score:=coalesce(new.base_reliability_score,new.reliability_score);
 else
  new.base_lead_time_days:=old.base_lead_time_days;
  new.base_unit_cost:=old.base_unit_cost;
  new.base_reliability_score:=old.base_reliability_score;
 end if;
 return new;
end; $function$
;
drop trigger if exists preserve_competition_supplier_baseline on public.competition_suppliers;
create trigger preserve_competition_supplier_baseline before insert or update on public.competition_suppliers
 for each row execute function public.preserve_competition_supplier_baseline();

CREATE OR REPLACE FUNCTION public.competition_update_supplier_terms(p_supplier_id uuid, p_lead_time_days integer, p_unit_cost numeric, p_reliability_score numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_supplier public.competition_suppliers%rowtype;
 v_min_lead integer; v_max_lead integer; v_min_cost numeric; v_max_cost numeric;
 v_min_reliability numeric; v_max_reliability numeric;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_supplier from public.competition_suppliers where id=p_supplier_id for update;
 if not found then raise exception 'Supplier not found'; end if;
 if not exists(select 1 from public.competitions where id=v_supplier.competition_id and status='active') then raise exception 'Competition is not active'; end if;
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
end; $function$
;
revoke all on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) from public,anon;
grant execute on function public.competition_update_supplier_terms(uuid,integer,numeric,numeric) to authenticated;
