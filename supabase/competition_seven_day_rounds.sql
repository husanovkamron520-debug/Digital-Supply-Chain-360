-- Five rounds now span 28 virtual days, leaving a final delivery and reconciliation window after the longest company baseline lead time.
CREATE OR REPLACE FUNCTION public.competition_advance_round(p_competition_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 update public.competition_simulation_clock set current_round=current_round+1,virtual_now=virtual_now+interval '7 days',updated_at=now()
 where competition_id=p_competition_id returning * into v_clock;
 update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select p_competition_id,t.id,t.classroom_id,(select auth.uid()),'teacher','round_advanced',
  'Simulation advanced to round '||v_clock.current_round,
  jsonb_build_object('round',v_clock.current_round,'virtual_now',v_clock.virtual_now,'days_advanced',7)
 from public.competition_teams t where t.competition_id=p_competition_id;
 return jsonb_build_object('current_round',v_clock.current_round,'round_limit',v_clock.round_limit,
  'virtual_now',v_clock.virtual_now,'days_advanced',7,'inventory_holding_cost_applied',true);
end; $function$
;
CREATE OR REPLACE FUNCTION public.initialize_competition_rounds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   jsonb_build_object('round',n,'virtual_days_advanced_after_round',7,
    'focus',case n when 1 then 'Supplier selection, sourcing and inventory policy'
     when 2 then 'Production planning and stock availability'
     when 3 then 'Customer fulfilment and transport execution'
     when 4 then 'Cost, service and risk optimisation' else 'Cross-functional performance' end)
  from generate_series(1,v_rounds) n
  on conflict(competition_id,round_number) do nothing;
 end if;
 return new;
end; $function$
;
revoke all on function public.competition_advance_round(uuid) from public,anon;
grant execute on function public.competition_advance_round(uuid) to authenticated;
