-- Keep round brief metadata aligned with the simulation clock's 3-day advance.
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
   jsonb_build_object('round',n,'virtual_days_advanced_after_round',3,
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
