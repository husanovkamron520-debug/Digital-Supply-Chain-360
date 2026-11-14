-- Five rounds span 28 virtual days: four advances of seven days.
-- The fifth round is reserved for final deliveries and reconciliation.
alter table public.competitions alter column settings set default '{"round_count":5,"round_duration_minutes":20,"scoring_version":"v1"}'::jsonb;
CREATE OR REPLACE FUNCTION public.create_competition(p_classroom_id uuid, p_title text, p_settings jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid; v_title text:=trim(coalesce(p_title,''));
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then raise exception 'Only the classroom teacher can create a competition'; end if;
 if char_length(v_title) not between 3 and 140 then raise exception 'Competition title must be 3-140 characters'; end if;
 if jsonb_typeof(coalesce(p_settings,'{}'::jsonb)) <> 'object' then raise exception 'Settings must be a JSON object'; end if;
 insert into public.competitions(classroom_id,created_by,title,settings)
 values(p_classroom_id,(select auth.uid()),v_title,
  '{"round_count":5,"round_duration_minutes":20,"scoring_version":"v1"}'::jsonb || coalesce(p_settings,'{}'::jsonb))
 returning id into v_id;
 return v_id;
end;
$function$
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
  v_rounds:=greatest(1,least(20,coalesce((new.settings->>'round_count')::integer,5)));
  insert into public.competition_simulation_clock(competition_id,classroom_id,current_round,round_limit,virtual_now)
  values(new.id,new.classroom_id,1,v_rounds,now()) on conflict(competition_id) do nothing;
  insert into public.competition_rounds(competition_id,round_number,title,status,brief)
  select new.id,n,
   case n when 1 then 'Round 1 · Source & plan' when 2 then 'Round 2 · Produce & replenish'
    when 3 then 'Round 3 · Fulfil & deliver' when 4 then 'Round 4 · Optimise & recover' when 5 then 'Round 5 · Final delivery & evaluation'
    else 'Round '||n||' · Continuous improvement' end,
   case when n=1 then 'active' else 'locked' end,
   jsonb_build_object('round',n,'virtual_days_advanced_after_round',7,
    'focus',case n when 1 then 'Supplier selection, sourcing and inventory policy'
     when 2 then 'Production planning and stock availability'
     when 3 then 'Customer fulfilment and transport execution'
     when 4 then 'Cost, service and risk optimisation' when 5 then 'Final deliveries, reconciliation and performance review' else 'Cross-functional performance' end)
  from generate_series(1,v_rounds) n
  on conflict(competition_id,round_number) do nothing;
 end if;
 return new;
end; $function$
;
