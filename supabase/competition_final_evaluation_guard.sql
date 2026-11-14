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
  if exists(
   select 1 from public.competition_teams t
   where t.competition_id=p_competition_id and (
    not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='procurement')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='supplier')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='manufacturer')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='warehouse')
    or not exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=t.id and m.operational_role='transport')
   )
  ) then
   raise exception 'Every team needs Procurement, Supplier, Manufacturer, Warehouse and Transport roles (at least five students per team) before starting';
  end if;
 end if;
 if v_current='completed' then raise exception 'Completed competitions cannot be reopened'; end if;
 if v_current='draft' and p_status not in ('active') then raise exception 'A draft competition can only be started'; end if;
 if p_status='completed' then
  select current_round,round_limit into v_round,v_round_limit from public.competition_simulation_clock where competition_id=p_competition_id for update;
  if v_round is null then raise exception 'Simulation clock is not initialized'; end if;
  if v_round<v_round_limit then raise exception 'Complete all simulation rounds before finalising the competition'; end if;
  if exists(select 1 from public.competition_decisions where competition_id=p_competition_id and score is null) then
   raise exception 'Evaluate all submitted student decisions before finalising the competition';
  end if;
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
revoke all on function public.set_competition_status(uuid,text) from public,anon;
grant execute on function public.set_competition_status(uuid,text) to authenticated;