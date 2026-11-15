alter table public.competition_tasks
  add column if not exists score numeric(5,2),
  add column if not exists feedback text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.competition_tasks'::regclass
      and conname='competition_tasks_score_range'
  ) then
    alter table public.competition_tasks
      add constraint competition_tasks_score_range
      check (score is null or (score >= 0 and score <= 100));
  end if;
end;
$$;

create or replace function public.evaluate_competition_task(
  p_task_id uuid,
  p_score numeric,
  p_feedback text default ''
)
returns numeric
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_task public.competition_tasks%rowtype;
  v_student_id uuid;
  v_role_count integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required';
  end if;
  if p_score is null or p_score < 0 or p_score > 100 then
    raise exception 'Score must be between 0 and 100';
  end if;

  select * into v_task
  from public.competition_tasks
  where id=p_task_id
  for update;

  if not found then raise exception 'Task not found'; end if;
  if not public.is_class_teacher(v_task.classroom_id) then
    raise exception 'Only the classroom teacher can evaluate tasks';
  end if;
  if v_task.status <> 'submitted' then
    raise exception 'Only submitted tasks can be evaluated';
  end if;

  if v_task.assigned_to is not null then
    v_student_id := v_task.assigned_to;
    if not exists (
      select 1 from public.competition_team_members m
      where m.competition_id=v_task.competition_id
        and m.team_id=v_task.team_id
        and m.student_id=v_student_id
    ) then
      raise exception 'Assigned student is not a member of this team';
    end if;
  elsif v_task.assigned_role is not null then
    select count(*),min(m.student_id::text)::uuid
      into v_role_count,v_student_id
    from public.competition_team_members m
    where m.competition_id=v_task.competition_id
      and m.team_id=v_task.team_id
      and m.operational_role=v_task.assigned_role;
    if v_role_count <> 1 then
      raise exception 'This role must have exactly one team member before the task can be graded';
    end if;
  else
    raise exception 'Task must be assigned to a student or operational role before grading';
  end if;

  update public.competition_tasks
  set score=round(p_score,2),
      feedback=left(coalesce(p_feedback,''),2000),
      status='approved',
      reviewed_by=(select auth.uid()),
      reviewed_at=now(),
      review_note=left(coalesce(p_feedback,''),1000)
  where id=p_task_id;

  return round(p_score,2);
end;
$function$;

revoke all on function public.evaluate_competition_task(uuid,numeric,text) from public,anon;
grant execute on function public.evaluate_competition_task(uuid,numeric,text) to authenticated;

drop function if exists public.get_competition_individual_leaderboard(uuid);

create function public.get_competition_individual_leaderboard(p_competition_id uuid)
returns table(
  full_name text,
  team_name text,
  decision_count integer,
  evaluated_decisions integer,
  task_count integer,
  evaluated_tasks integer,
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
  activity_scores as (
    select d.student_id,d.team_id,d.score,'decision'::text as kind
    from public.competition_decisions d
    where d.competition_id=p_competition_id and d.score is not null
    union all
    select ta.student_id,ta.team_id,ta.score,'task'::text
    from task_assignments ta
    where ta.score is not null
  ),
  decision_counts as (
    select d.student_id,d.team_id,
      count(*)::integer as decision_count,
      count(d.score)::integer as evaluated_decisions,
      max(d.score) as best_decision_score
    from public.competition_decisions d
    where d.competition_id=p_competition_id
    group by d.student_id,d.team_id
  ),
  task_counts as (
    select ta.student_id,ta.team_id,
      count(*)::integer as task_count,
      count(ta.score)::integer as evaluated_tasks
    from task_assignments ta
    group by ta.student_id,ta.team_id
  ),
  scored as (
    select a.student_id,a.team_id,round(avg(a.score),2) as average_score
    from activity_scores a
    group by a.student_id,a.team_id
  )
  select
    p.full_name::text,
    team.name::text,
    coalesce(dc.decision_count,0),
    coalesce(dc.evaluated_decisions,0),
    coalesce(tc.task_count,0),
    coalesce(tc.evaluated_tasks,0),
    scored.average_score,
    dc.best_decision_score
  from (
    select student_id,team_id from decision_counts
    union
    select student_id,team_id from task_counts
  ) roster
  join public.profiles p on p.id=roster.student_id
  join public.competition_teams team on team.id=roster.team_id
  left join decision_counts dc on dc.student_id=roster.student_id and dc.team_id=roster.team_id
  left join task_counts tc on tc.student_id=roster.student_id and tc.team_id=roster.team_id
  left join scored on scored.student_id=roster.student_id and scored.team_id=roster.team_id
  order by scored.average_score desc nulls last,coalesce(dc.evaluated_decisions,0)+coalesce(tc.evaluated_tasks,0) desc,p.full_name;
end;
$function$;

revoke all on function public.get_competition_individual_leaderboard(uuid) from public,anon;
grant execute on function public.get_competition_individual_leaderboard(uuid) to authenticated;
