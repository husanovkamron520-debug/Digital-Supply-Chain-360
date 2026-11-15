do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.competition_tasks'::regclass
      and conname='competition_tasks_approved_requires_score'
  ) then
    alter table public.competition_tasks
      add constraint competition_tasks_approved_requires_score
      check (status <> 'approved' or score is not null);
  end if;
end;
$$;

create or replace function public.review_competition_task(
  p_task_id uuid,
  p_approved boolean,
  p_review_note text default ''
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_task public.competition_tasks%rowtype;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required';
  end if;
  if p_approved then
    raise exception 'A task can only be approved with a numeric score. Use evaluate_competition_task.';
  end if;

  select * into v_task
  from public.competition_tasks
  where id=p_task_id
  for update;
  if not found then raise exception 'Task not found'; end if;
  if not public.is_class_teacher(v_task.classroom_id) then
    raise exception 'Only the classroom teacher can review tasks';
  end if;
  if v_task.status <> 'submitted' then
    raise exception 'Only submitted tasks can be reviewed';
  end if;

  update public.competition_tasks
  set status='rejected',
      reviewed_by=(select auth.uid()),
      reviewed_at=now(),
      review_note=left(coalesce(p_review_note,''),1000)
  where id=p_task_id;
  return true;
end;
$function$;

revoke all on function public.review_competition_task(uuid,boolean,text) from public,anon;
grant execute on function public.review_competition_task(uuid,boolean,text) to authenticated;
