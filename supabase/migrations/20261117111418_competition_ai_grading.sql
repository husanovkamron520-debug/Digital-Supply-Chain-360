-- SupplyChain14 AI grading metadata and private answer-key storage.
-- The existing task score/feedback fields remain the visible summary.
alter table public.competition_tasks
  add column if not exists ai_grade jsonb,
  add column if not exists ai_graded_at timestamptz,
  add column if not exists ai_grading_started_at timestamptz,
  add column if not exists ai_model text;

create table if not exists public.competition_task_grading_specs (
  task_id uuid primary key references public.competition_tasks(id) on delete cascade,
  rubric jsonb not null,
  reference_answer jsonb not null default '{}'::jsonb,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint competition_task_grading_specs_rubric_object
    check (jsonb_typeof(rubric) = 'object'),
  constraint competition_task_grading_specs_answer_object
    check (jsonb_typeof(reference_answer) = 'object')
);

alter table public.competition_task_grading_specs enable row level security;

drop policy if exists competition_task_grading_specs_teacher_all
  on public.competition_task_grading_specs;
create policy competition_task_grading_specs_teacher_all
  on public.competition_task_grading_specs
  for all to authenticated
  using (
    exists (
      select 1
      from public.competition_tasks t
      where t.id = competition_task_grading_specs.task_id
        and public.is_class_teacher(t.classroom_id)
    )
  )
  with check (
    created_by = (select auth.uid())
    and exists (
      select 1
      from public.competition_tasks t
      where t.id = competition_task_grading_specs.task_id
        and public.is_class_teacher(t.classroom_id)
    )
  );

revoke all on public.competition_task_grading_specs from public, anon;
grant select, insert, update, delete
  on public.competition_task_grading_specs to authenticated;

comment on table public.competition_task_grading_specs is
  'Private teacher-managed rubric and reference answer for SupplyChain14 AI grading. Students cannot read this table.';
comment on column public.competition_tasks.ai_grade is
  'Structured AI feedback and criterion-level scores; does not itself approve the task.';
comment on column public.competition_tasks.ai_grading_started_at is
  'Atomic claim timestamp preventing duplicate concurrent AI grading requests.';
