drop function if exists public.get_competition_individual_leaderboard(uuid);

create function public.get_competition_individual_leaderboard(p_competition_id uuid)
returns table(
  full_name text,
  team_name text,
  decision_count integer,
  evaluated_decisions integer,
  decision_average numeric,
  task_count integer,
  evaluated_tasks integer,
  task_average numeric,
  average_score numeric,
  best_decision_score numeric
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_classroom_id uuid;
  v_status text;
begin
  if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
  select classroom_id,status into v_classroom_id,v_status
  from public.competitions where id=p_competition_id;
  if not found then raise exception 'Competition not found'; end if;
  if not public.is_class_member(v_classroom_id) then
    raise exception 'You are not a member of this classroom';
  end if;
  if v_status not in ('active','paused','completed') then
    raise exception 'Competition results are not public yet';
  end if;

  return query
  with task_assignments as (
    select
      task.id as task_id,
      task.team_id,
      coalesce(task.assigned_to, role_member.student_id) as student_id,
      task.score
    from public.competition_tasks task
    left join lateral (
      select min(m.student_id::text)::uuid as student_id
      from public.competition_team_members m
      where m.competition_id=task.competition_id
        and m.team_id=task.team_id
        and m.operational_role=task.assigned_role
      having count(*)=1
    ) role_member on task.assigned_to is null
    where task.competition_id=p_competition_id
      and (task.assigned_to is not null or role_member.student_id is not null)
  ),
  decision_counts as (
    select d.student_id,d.team_id,
      count(*)::integer as decision_count,
      count(d.score)::integer as evaluated_decisions,
      round(avg(d.score),2) as decision_average,
      max(d.score) as best_decision_score
    from public.competition_decisions d
    where d.competition_id=p_competition_id
    group by d.student_id,d.team_id
  ),
  task_counts as (
    select ta.student_id,ta.team_id,
      count(*)::integer as task_count,
      count(ta.score)::integer as evaluated_tasks,
      round(avg(ta.score),2) as task_average
    from task_assignments ta
    group by ta.student_id,ta.team_id
  ),
  roster as (
    select student_id,team_id from decision_counts
    union
    select student_id,team_id from task_counts
  )
  select
    p.full_name::text,
    team.name::text,
    coalesce(dc.decision_count,0),
    coalesce(dc.evaluated_decisions,0),
    dc.decision_average,
    coalesce(tc.task_count,0),
    coalesce(tc.evaluated_tasks,0),
    tc.task_average,
    case
      when dc.decision_average is not null and tc.task_average is not null
        then round((dc.decision_average+tc.task_average)/2,2)
      else coalesce(dc.decision_average,tc.task_average)
    end,
    dc.best_decision_score
  from roster
  join public.profiles p on p.id=roster.student_id
  join public.competition_teams team on team.id=roster.team_id
  left join decision_counts dc on dc.student_id=roster.student_id and dc.team_id=roster.team_id
  left join task_counts tc on tc.student_id=roster.student_id and tc.team_id=roster.team_id
  order by
    case
      when dc.decision_average is not null and tc.task_average is not null
        then round((dc.decision_average+tc.task_average)/2,2)
      else coalesce(dc.decision_average,tc.task_average)
    end desc nulls last,
    coalesce(dc.evaluated_decisions,0)+coalesce(tc.evaluated_tasks,0) desc,
    p.full_name;
end;
$function$;

revoke all on function public.get_competition_individual_leaderboard(uuid) from public,anon;
grant execute on function public.get_competition_individual_leaderboard(uuid) to authenticated;
