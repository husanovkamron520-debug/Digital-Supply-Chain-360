-- Digital Supply Chain 360
-- Supabase PostgreSQL foundation: profiles, classrooms, memberships and simulated operations.
-- Apply this file in Supabase SQL Editor. New sign-ups are students by default.
-- Promote a trusted teacher manually from the Supabase SQL Editor (see README).

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  platform_role text not null default 'student'
    check (platform_role in ('student', 'teacher')),
  created_at timestamptz not null default now()
);

create table if not exists public.classrooms (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete restrict,
  name text not null check (char_length(name) between 2 and 100),
  join_code text not null unique check (join_code ~ '^[A-Z0-9]{6,10}$'),
  created_at timestamptz not null default now()
);

create table if not exists public.classroom_members (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  operational_role text not null default 'customer'
    check (operational_role in ('supplier','manufacturer','warehouse','transport','retailer','customer')),
  joined_at timestamptz not null default now(),
  unique (classroom_id, student_id)
);

create table if not exists public.scenarios (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  title text not null check (char_length(title) between 2 and 140),
  status text not null default 'draft' check (status in ('draft','active','completed')),
  configuration jsonb not null default '{}'::jsonb,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  scenario_id uuid references public.scenarios(id) on delete set null,
  created_by uuid not null references public.profiles(id),
  order_number text not null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  status text not null default 'created'
    check (status in ('created','approved','in_production','ready','in_transit','delivered','delayed','cancelled')),
  due_at timestamptz,
  created_at timestamptz not null default now(),
  unique (classroom_id, order_number)
);

create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  scenario_id uuid references public.scenarios(id) on delete cascade,
  sku text not null,
  item_name text not null,
  quantity integer not null default 0 check (quantity >= 0),
  reorder_level integer not null default 0 check (reorder_level >= 0),
  updated_at timestamptz not null default now(),
  unique (classroom_id, scenario_id, sku)
);

create table if not exists public.shipments (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  scenario_id uuid references public.scenarios(id) on delete set null,
  order_id uuid references public.orders(id) on delete set null,
  created_by uuid not null references public.profiles(id),
  origin text not null,
  destination text not null,
  carrier text not null default 'Demo carrier',
  status text not null default 'planned'
    check (status in ('planned','dispatched','in_transit','delayed','delivered')),
  eta timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.activity_logs (
  id bigint generated always as identity primary key,
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  scenario_id uuid references public.scenarios(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists classroom_members_student_idx on public.classroom_members(student_id);
create index if not exists scenarios_classroom_idx on public.scenarios(classroom_id, created_at desc);
create index if not exists orders_classroom_idx on public.orders(classroom_id, created_at desc);
create index if not exists shipments_classroom_idx on public.shipments(classroom_id, created_at desc);
create index if not exists activity_logs_classroom_idx on public.activity_logs(classroom_id, created_at desc);

-- Create a student profile automatically after Supabase Auth sign-up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Security-definer helpers avoid recursive RLS checks between classrooms and memberships.
create or replace function public.is_class_teacher(p_classroom_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.classrooms c
    where c.id = p_classroom_id and c.teacher_id = auth.uid()
  );
$$;

create or replace function public.is_class_member(p_classroom_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.classroom_members m
    where m.classroom_id = p_classroom_id and m.student_id = auth.uid()
  ) or public.is_class_teacher(p_classroom_id);
$$;

-- Join by code is handled on the server; students cannot forge membership rows.
create or replace function public.join_classroom(p_join_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_classroom_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'You must sign in first';
  end if;

  select platform_role into v_role
  from public.profiles where id = auth.uid();

  if v_role is distinct from 'student' then
    raise exception 'Only student accounts can join a classroom';
  end if;

  select id into v_classroom_id
  from public.classrooms
  where join_code = upper(trim(p_join_code));

  if v_classroom_id is null then
    raise exception 'Invalid classroom code';
  end if;

  insert into public.classroom_members (classroom_id, student_id)
  values (v_classroom_id, auth.uid())
  on conflict (classroom_id, student_id) do nothing;

  return v_classroom_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.classrooms enable row level security;
alter table public.classroom_members enable row level security;
alter table public.scenarios enable row level security;
alter table public.orders enable row level security;
alter table public.inventory enable row level security;
alter table public.shipments enable row level security;
alter table public.activity_logs enable row level security;

-- Profiles: users can read/update their own basic profile; teachers can view their class members.
drop policy if exists "profiles_select_self_or_teacher" on public.profiles;
create policy "profiles_select_self_or_teacher" on public.profiles
for select to authenticated
using (
  id = auth.uid()
  or exists (
    select 1 from public.classroom_members m
    where m.student_id = profiles.id and public.is_class_teacher(m.classroom_id)
  )
);

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Platform roles are not exposed for client-side inserts or updates.
revoke insert, update on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name) on public.profiles to authenticated;

-- Classrooms: teachers own and manage their classes; members can view them.
drop policy if exists "classrooms_select_members" on public.classrooms;
create policy "classrooms_select_members" on public.classrooms
for select to authenticated
using (public.is_class_member(id));

drop policy if exists "classrooms_insert_teacher" on public.classrooms;
create policy "classrooms_insert_teacher" on public.classrooms
for insert to authenticated
with check (
  teacher_id = auth.uid()
  and exists (select 1 from public.profiles p where p.id = auth.uid() and p.platform_role = 'teacher')
);

drop policy if exists "classrooms_update_teacher" on public.classrooms;
create policy "classrooms_update_teacher" on public.classrooms
for update to authenticated
using (teacher_id = auth.uid())
with check (teacher_id = auth.uid());

drop policy if exists "classrooms_delete_teacher" on public.classrooms;
create policy "classrooms_delete_teacher" on public.classrooms
for delete to authenticated
using (teacher_id = auth.uid());

-- Memberships: students see their own membership; teachers see/manage members of their classes.
drop policy if exists "members_select_self_or_teacher" on public.classroom_members;
create policy "members_select_self_or_teacher" on public.classroom_members
for select to authenticated
using (student_id = auth.uid() or public.is_class_teacher(classroom_id));

drop policy if exists "members_teacher_update" on public.classroom_members;
create policy "members_teacher_update" on public.classroom_members
for update to authenticated
using (public.is_class_teacher(classroom_id))
with check (public.is_class_teacher(classroom_id));

drop policy if exists "members_teacher_delete" on public.classroom_members;
create policy "members_teacher_delete" on public.classroom_members
for delete to authenticated
using (public.is_class_teacher(classroom_id));

-- join_classroom() is the only student join path; direct membership inserts are not granted.
revoke insert on public.classroom_members from anon, authenticated;
grant select, update, delete on public.classroom_members to authenticated;

-- Scenarios: all class members can view; only the class teacher manages scenarios.
drop policy if exists "scenarios_select_members" on public.scenarios;
create policy "scenarios_select_members" on public.scenarios
for select to authenticated using (public.is_class_member(classroom_id));

drop policy if exists "scenarios_insert_teacher" on public.scenarios;
create policy "scenarios_insert_teacher" on public.scenarios
for insert to authenticated
with check (created_by = auth.uid() and public.is_class_teacher(classroom_id));

drop policy if exists "scenarios_update_teacher" on public.scenarios;
create policy "scenarios_update_teacher" on public.scenarios
for update to authenticated using (public.is_class_teacher(classroom_id))
with check (public.is_class_teacher(classroom_id));

drop policy if exists "scenarios_delete_teacher" on public.scenarios;
create policy "scenarios_delete_teacher" on public.scenarios
for delete to authenticated using (public.is_class_teacher(classroom_id));

-- Operational records: class members can read; authenticated members can create records.
-- Updates/deletes are restricted to the teacher for controlled classroom simulations.
do $$
declare
  t text;
begin
  foreach t in array array['orders','inventory','shipments'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select_members', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_class_member(classroom_id))', t || '_select_members', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert_members', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_class_member(classroom_id))', t || '_insert_members', t);
    execute format('drop policy if exists %I on public.%I', t || '_update_teacher', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_class_teacher(classroom_id)) with check (public.is_class_teacher(classroom_id))', t || '_update_teacher', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete_teacher', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_class_teacher(classroom_id))', t || '_delete_teacher', t);
  end loop;
end $$;

-- Activity log: class members can read; members can append; no client-side editing/deletion.
drop policy if exists "activity_select_members" on public.activity_logs;
create policy "activity_select_members" on public.activity_logs
for select to authenticated using (public.is_class_member(classroom_id));

drop policy if exists "activity_insert_members" on public.activity_logs;
create policy "activity_insert_members" on public.activity_logs
for insert to authenticated
with check (actor_id = auth.uid() and public.is_class_member(classroom_id));

revoke update, delete on public.activity_logs from anon, authenticated;
grant select, insert on public.activity_logs to authenticated;

grant select on public.classrooms, public.classroom_members, public.scenarios,
  public.orders, public.inventory, public.shipments to authenticated;
grant insert, update, delete on public.classrooms, public.scenarios,
  public.orders, public.inventory, public.shipments to authenticated;
grant usage, select on sequence public.activity_logs_id_seq to authenticated;

grant execute on function public.join_classroom(text) to authenticated;
