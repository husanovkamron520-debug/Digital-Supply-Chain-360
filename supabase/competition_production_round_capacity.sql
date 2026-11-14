-- Enforce aggregate production capacity per round and close production during the final delivery round.
alter table public.competition_production_runs add column if not exists production_round integer not null default 1;
alter table public.competition_production_runs drop constraint if exists competition_production_runs_round_check;
alter table public.competition_production_runs add constraint competition_production_runs_round_check check(production_round between 1 and 20);
create index if not exists competition_production_team_round_idx on public.competition_production_runs(team_id,production_round) where status='completed';

CREATE OR REPLACE FUNCTION public.competition_complete_production(p_team_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_team public.competition_teams%rowtype;
 v_clock public.competition_simulation_clock%rowtype;
 v_competition_id uuid; v_round_total integer;
 v_raw integer; v_raw_unit_cost numeric; v_fg integer; v_cost numeric; v_run uuid;
 v_profile jsonb; v_conversion numeric; v_product text; v_raw_sku text:='RM-001';
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 -- Lock the simulation clock before the team row, matching round-advance lock order.
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock has not been initialized'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if v_team.competition_id<>v_competition_id then raise exception 'Team competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if v_clock.current_round>=v_clock.round_limit then raise exception 'Production is closed in the final round; use available finished stock to complete deliveries'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['manufacturer']) then raise exception 'Only the assigned Production Manager can run production'; end if;
 if p_quantity is null or p_quantity not between 1 and v_team.production_capacity_units then raise exception 'Production quantity exceeds the per-round capacity'; end if;
 select coalesce(sum(produced_quantity),0) into v_round_total
 from public.competition_production_runs
 where team_id=p_team_id and production_round=v_clock.current_round and status='completed';
 if v_round_total+p_quantity>v_team.production_capacity_units then
  raise exception 'Round % capacity exceeded: % units already produced; only % units remain',
   v_clock.current_round,v_round_total,greatest(0,v_team.production_capacity_units-v_round_total);
 end if;
 select ct.operating_profile into v_profile
 from public.company_templates ct join public.competition_teams t on t.company_template_id=ct.id where t.id=p_team_id;
 v_conversion:=coalesce((v_profile->>'conversion_cost_per_unit')::numeric,3);
 v_product:=coalesce(v_profile->>'product_name','Finished product');
 select quantity,unit_cost into v_raw,v_raw_unit_cost
 from public.competition_inventory where team_id=p_team_id and sku=v_raw_sku for update;
 if not found or v_raw<p_quantity then raise exception 'Insufficient raw materials. Purchase and receive more first.'; end if;
 v_cost:=p_quantity*v_conversion;
 if v_team.cash_balance<v_cost then raise exception 'Insufficient company cash for production'; end if;
 update public.competition_inventory set quantity=quantity-p_quantity,updated_at=now()
 where team_id=p_team_id and sku=v_raw_sku;
 insert into public.competition_inventory(competition_id,team_id,classroom_id,sku,item_name,item_type,quantity,reorder_level,unit_cost)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,'finished_goods',p_quantity,60,v_raw_unit_cost+v_conversion)
 on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,
  unit_cost=excluded.unit_cost,updated_at=now()
 returning quantity into v_fg;
 insert into public.competition_production_runs(competition_id,team_id,classroom_id,sku,item_name,planned_quantity,produced_quantity,raw_material_sku,conversion_cost_per_unit,status,production_round,completed_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,'FG-001',v_product,p_quantity,p_quantity,v_raw_sku,v_conversion,'completed',v_clock.current_round,now())
 returning id into v_run;
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=p_team_id;
 insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'production',-v_cost,'Production conversion cost',v_run);
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'manufacturer','production_completed','Produced '||p_quantity||' finished units',
 jsonb_build_object('production_run_id',v_run,'production_round',v_clock.current_round,'round_production_total',v_round_total+p_quantity,
 'round_capacity',v_team.production_capacity_units,'raw_material_remaining',v_raw-p_quantity,'finished_stock',v_fg,
 'cost',v_cost,'finished_unit_cost',v_raw_unit_cost+v_conversion));
 return jsonb_build_object('production_run_id',v_run,'production_round',v_clock.current_round,'produced_quantity',p_quantity,
  'round_production_total',v_round_total+p_quantity,'remaining_round_capacity',v_team.production_capacity_units-v_round_total-p_quantity,
  'finished_stock',v_fg,'raw_material_remaining',v_raw-p_quantity,'cost',v_cost);
end; $function$
;
revoke all on function public.competition_complete_production(uuid,integer) from public,anon;
grant execute on function public.competition_complete_production(uuid,integer) to authenticated;
