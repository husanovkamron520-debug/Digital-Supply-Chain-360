-- Optimize auth helper evaluation in RLS policies without changing access rules.
create or replace function public.current_user_is_teacher()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and platform_role = 'teacher'
  );
$$;

create or replace function public.is_class_teacher(p_classroom_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.classrooms c
    where c.id = p_classroom_id and c.teacher_id = (select auth.uid())
  );
$$;

create or replace function public.is_class_member(p_classroom_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.classroom_members m
    where m.classroom_id = p_classroom_id and m.student_id = (select auth.uid())
  ) or public.is_class_teacher(p_classroom_id);
$$;

alter policy activity_insert_members on public.activity_logs
  with check ((actor_id = (select auth.uid())) and is_class_member(classroom_id));

alter policy members_select_self_or_teacher on public.classroom_members
  using ((student_id = (select auth.uid())) or is_class_teacher(classroom_id));

alter policy classrooms_delete_teacher on public.classrooms
  using (teacher_id = (select auth.uid()));

alter policy classrooms_insert_teacher on public.classrooms
  with check ((teacher_id = (select auth.uid())) and current_user_is_teacher());

alter policy classrooms_update_teacher on public.classrooms
  using (teacher_id = (select auth.uid()))
  with check (teacher_id = (select auth.uid()));

alter policy orders_insert_members on public.orders
  with check (is_class_member(classroom_id) and (created_by = (select auth.uid())));

alter policy profiles_select_self_or_teacher on public.profiles
  using (
    (id = (select auth.uid()))
    or exists (
      select 1 from public.classroom_members m
      where m.student_id = profiles.id and is_class_teacher(m.classroom_id)
    )
  );

alter policy profiles_update_self on public.profiles
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

alter policy scenarios_insert_teacher on public.scenarios
  with check ((created_by = (select auth.uid())) and is_class_teacher(classroom_id));

alter policy shipments_insert_members on public.shipments
  with check (is_class_member(classroom_id) and (created_by = (select auth.uid())));
