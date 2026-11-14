-- SupplyChain14 Competition Engine foundation
-- Apply after the existing classroom, operational and scenario migrations.
-- All writes are performed through SECURITY DEFINER RPCs; client table writes stay revoked.

create table if not exists public.company_templates (
 id uuid primary key default gen_random_uuid(), slug text not null unique, name text not null,
 industry text not null, business_model text not null,
 operating_profile jsonb not null default '{}'::jsonb,
 scoring_weights jsonb not null default '{}'::jsonb,
 active boolean not null default true, created_at timestamptz not null default now()
);
insert into public.company_templates(slug,name,industry,business_model,operating_profile,scoring_weights) values
('lean-automotive','Lean Automotive Manufacturer','Automotive manufacturing','Make-to-stock with lean/JIT replenishment',
 '{"capacity_units_per_round":1200,"baseline_lead_time_days":7,"safety_stock_days":3,"supplier_count":3,"demand_volatility":"medium","capital_index":100,"constraints":["line_balance","supplier_reliability","quality"]}'::jsonb,
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb),
('omnichannel-retail','Omnichannel Retail & Fulfilment','Retail and e-commerce','Omnichannel fulfilment with distributed inventory',
 '{"capacity_units_per_round":1500,"baseline_lead_time_days":3,"safety_stock_days":5,"supplier_count":5,"demand_volatility":"high","capital_index":100,"constraints":["forecast_accuracy","warehouse_capacity","last_mile"]}'::jsonb,
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb),
('flatpack-global','Flat-pack Global Supply Network','Furniture and home goods','Global sourcing, consolidation and distribution',
 '{"capacity_units_per_round":1000,"baseline_lead_time_days":14,"safety_stock_days":7,"supplier_count":4,"demand_volatility":"medium","capital_index":100,"constraints":["container_utilisation","sourcing_risk","storage_cost"]}'::jsonb,
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb),
('beverage-fast-moving','Fast-moving Beverage Producer','Food and beverage','High-volume production and regional distribution',
 '{"capacity_units_per_round":1800,"baseline_lead_time_days":4,"safety_stock_days":4,"supplier_count":4,"demand_volatility":"high","capital_index":100,"constraints":["shelf_life","production_schedule","route_efficiency"]}'::jsonb,
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb)
on conflict(slug) do update set name=excluded.name,industry=excluded.industry,business_model=excluded.business_model,
 operating_profile=excluded.operating_profile,scoring_weights=excluded.scoring_weights,active=true;

create table if not exists public.competitions(
 id uuid primary key default gen_random_uuid(), classroom_id uuid not null references public.classrooms(id) on delete cascade,
 created_by uuid not null references public.profiles(id),
 title text not null check(char_length(title) between 3 and 140),
 status text not null default 'draft' check(status in('draft','active','paused','completed')),
 settings jsonb not null default '{"round_count":4,"round_duration_minutes":20,"scoring_version":"v1"}'::jsonb,
 starts_at timestamptz,ends_at timestamptz,completed_at timestamptz,created_at timestamptz not null default now()
);
create index if not exists competitions_classroom_idx on public.competitions(classroom_id,created_at desc);

create table if not exists public.competition_teams(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 classroom_id uuid not null references public.classrooms(id) on delete cascade,
 company_template_id uuid not null references public.company_templates(id),
 name text not null check(char_length(name) between 2 and 80),
 status text not null default 'active' check(status in('active','disqualified')),
 created_at timestamptz not null default now(),unique(competition_id,name),unique(id,competition_id,classroom_id)
);
create index if not exists competition_teams_competition_idx on public.competition_teams(competition_id);

create table if not exists public.competition_team_members(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null,classroom_id uuid not null,student_id uuid not null references public.profiles(id) on delete cascade,
 operational_role text not null check(operational_role in('procurement','supplier','manufacturer','warehouse','transport','retailer','customer','operations','finance','analyst')),
 joined_at timestamptz not null default now(),unique(competition_id,student_id),unique(team_id,student_id),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);
create index if not exists competition_team_members_student_idx on public.competition_team_members(student_id,competition_id);

create table if not exists public.competition_tasks(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 classroom_id uuid not null references public.classrooms(id) on delete cascade,
 assigned_to uuid references public.profiles(id) on delete set null,
 assigned_role text check(assigned_role is null or assigned_role in('procurement','supplier','manufacturer','warehouse','transport','retailer','customer','operations','finance','analyst')),
 title text not null check(char_length(title) between 3 and 140),description text not null default '',
 priority text not null default 'normal' check(priority in('low','normal','high','critical')),
 status text not null default 'pending' check(status in('pending','in_progress','submitted','approved','rejected')),
 due_at timestamptz,submission jsonb,submitted_at timestamptz,
 reviewed_by uuid references public.profiles(id),reviewed_at timestamptz,review_note text,
 created_by uuid not null references public.profiles(id),created_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade,
 check(assigned_to is not null or assigned_role is not null)
);
create index if not exists competition_tasks_team_idx on public.competition_tasks(competition_id,team_id,status);
create index if not exists competition_tasks_assignee_idx on public.competition_tasks(assigned_to,status,due_at);

create table if not exists public.competition_decisions(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 classroom_id uuid not null references public.classrooms(id) on delete cascade,
 student_id uuid not null references public.profiles(id),
 domain text not null check(domain in('procurement','inventory','production','transport','customer_service','finance','risk','strategy')),
 decision_type text not null check(char_length(decision_type) between 2 and 80),
 selected_option text not null check(char_length(selected_option) between 1 and 120),
 rationale text not null check(char_length(rationale) between 20 and 2000),
 inputs jsonb not null default '{}'::jsonb,outcome jsonb not null default '{}'::jsonb,
 score numeric(5,2) check(score is null or score between 0 and 100),feedback text,
 evaluated_by uuid references public.profiles(id),evaluated_at timestamptz,created_at timestamptz not null default now(),
 foreign key(team_id,competition_id,classroom_id) references public.competition_teams(id,competition_id,classroom_id) on delete cascade
);
create index if not exists competition_decisions_team_idx on public.competition_decisions(competition_id,team_id,created_at desc);
create index if not exists competition_decisions_student_idx on public.competition_decisions(competition_id,student_id,created_at desc);

create table if not exists public.competition_rounds(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 round_number integer not null check(round_number between 1 and 20),title text not null check(char_length(title) between 2 and 120),
 status text not null default 'locked' check(status in('locked','active','completed')),
 brief jsonb not null default '{}'::jsonb,starts_at timestamptz,ends_at timestamptz,
 created_at timestamptz not null default now(),unique(competition_id,round_number)
);
create table if not exists public.competition_score_snapshots(
 id uuid primary key default gen_random_uuid(),competition_id uuid not null references public.competitions(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,round_number integer,
 metrics jsonb not null default '{}'::jsonb,component_scores jsonb not null default '{}'::jsonb,
 total_score numeric(6,2) not null check(total_score between 0 and 100),calculated_at timestamptz not null default now(),
 unique(competition_id,team_id,round_number)
);
create index if not exists competition_scores_leaderboard_idx on public.competition_score_snapshots(competition_id,total_score desc,calculated_at desc);

create or replace function public.is_competition_member(p_competition_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.student_id=(select auth.uid())); $$;
create or replace function public.is_competition_team_member(p_competition_id uuid,p_team_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from public.competition_team_members m where m.competition_id=p_competition_id and m.team_id=p_team_id and m.student_id=(select auth.uid())); $$;

alter table public.company_templates enable row level security;
alter table public.competitions enable row level security;
alter table public.competition_teams enable row level security;
alter table public.competition_team_members enable row level security;
alter table public.competition_tasks enable row level security;
alter table public.competition_decisions enable row level security;
alter table public.competition_rounds enable row level security;
alter table public.competition_score_snapshots enable row level security;

drop policy if exists company_templates_read_authenticated on public.company_templates;
create policy company_templates_read_authenticated on public.company_templates for select to authenticated using(active);
drop policy if exists competitions_read_class on public.competitions;
create policy competitions_read_class on public.competitions for select to authenticated using(public.is_class_member(classroom_id));
drop policy if exists competition_teams_read_competition on public.competition_teams;
create policy competition_teams_read_competition on public.competition_teams for select to authenticated using(public.is_class_teacher(classroom_id) or public.is_competition_member(competition_id));
drop policy if exists competition_team_members_read_scope on public.competition_team_members;
create policy competition_team_members_read_scope on public.competition_team_members for select to authenticated using(
 student_id=(select auth.uid()) or public.is_class_teacher(classroom_id) or public.is_competition_team_member(competition_id,team_id));
drop policy if exists competition_tasks_read_scope on public.competition_tasks;
create policy competition_tasks_read_scope on public.competition_tasks for select to authenticated using(
 public.is_class_teacher(classroom_id) or exists(select 1 from public.competition_team_members m
 where m.competition_id=competition_tasks.competition_id and m.team_id=competition_tasks.team_id and m.student_id=(select auth.uid())));
drop policy if exists competition_decisions_read_scope on public.competition_decisions;
create policy competition_decisions_read_scope on public.competition_decisions for select to authenticated using(
 public.is_class_teacher(classroom_id) or exists(select 1 from public.competition_team_members m
 where m.competition_id=competition_decisions.competition_id and m.team_id=competition_decisions.team_id and m.student_id=(select auth.uid())));
drop policy if exists competition_rounds_read_scope on public.competition_rounds;
create policy competition_rounds_read_scope on public.competition_rounds for select to authenticated using(
 exists(select 1 from public.competitions c where c.id=competition_rounds.competition_id and public.is_class_member(c.classroom_id)));
drop policy if exists competition_scores_read_scope on public.competition_score_snapshots;
create policy competition_scores_read_scope on public.competition_score_snapshots for select to authenticated using(
 exists(select 1 from public.competitions c where c.id=competition_score_snapshots.competition_id
 and(public.is_class_teacher(c.classroom_id) or public.is_competition_member(c.id))));

revoke all on public.company_templates,public.competitions,public.competition_teams,public.competition_team_members,
 public.competition_tasks,public.competition_decisions,public.competition_rounds,public.competition_score_snapshots from anon,authenticated;
grant select on public.company_templates,public.competitions,public.competition_teams,public.competition_team_members,
 public.competition_tasks,public.competition_decisions,public.competition_rounds,public.competition_score_snapshots to authenticated;

create or replace function public.create_competition(p_classroom_id uuid,p_title text,p_settings jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_title text:=trim(coalesce(p_title,''));
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then raise exception 'Only the classroom teacher can create a competition'; end if;
 if char_length(v_title) not between 3 and 140 then raise exception 'Competition title must be 3-140 characters'; end if;
 if jsonb_typeof(coalesce(p_settings,'{}'::jsonb))<>'object' then raise exception 'Settings must be a JSON object'; end if;
 insert into public.competitions(classroom_id,created_by,title,settings)
 values(p_classroom_id,(select auth.uid()),v_title,'{"round_count":4,"round_duration_minutes":20,"scoring_version":"v1"}'::jsonb||coalesce(p_settings,'{}'::jsonb))
 returning id into v_id; return v_id;
end; $$;

create or replace function public.create_competition_team(p_competition_id uuid,p_team_name text,p_company_template_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Teams can only be configured while competition is in draft'; end if;
 if char_length(trim(coalesce(p_team_name,''))) not between 2 and 80 then raise exception 'Team name must be 2-80 characters'; end if;
 if not exists(select 1 from public.company_templates where id=p_company_template_id and active) then raise exception 'Active company template not found'; end if;
 insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
 values(p_competition_id,v_classroom_id,p_company_template_id,trim(p_team_name)) returning id into v_id; return v_id;
exception when unique_violation then raise exception 'Team name already exists in this competition';
end; $$;

create or replace function public.assign_competition_member(p_competition_id uuid,p_team_id uuid,p_student_id uuid,p_operational_role text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_comp_status text; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_comp_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can assign students'; end if;
 if v_comp_status<>'draft' then raise exception 'Team assignments are locked after competition starts'; end if;
 if not exists(select 1 from public.competition_teams t where t.id=p_team_id and t.competition_id=p_competition_id and t.classroom_id=v_classroom_id) then raise exception 'Team does not belong to this competition'; end if;
 if not exists(select 1 from public.classroom_members m where m.classroom_id=v_classroom_id and m.student_id=p_student_id) then raise exception 'Student is not a member of this classroom'; end if;
 if p_operational_role not in('procurement','supplier','manufacturer','warehouse','transport','retailer','customer','operations','finance','analyst') then raise exception 'Unsupported operational role'; end if;
 insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
 values(p_competition_id,p_team_id,v_classroom_id,p_student_id,p_operational_role) returning id into v_id; return v_id;
exception when unique_violation then raise exception 'This student is already assigned to a team in this competition';
end; $$;

create or replace function public.create_competition_task(
 p_competition_id uuid,p_team_id uuid,p_title text,p_description text,
 p_assigned_to uuid default null,p_assigned_role text default null,p_priority text default 'normal',p_due_at timestamptz default null)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can assign competition tasks'; end if;
 if v_status not in('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if not exists(select 1 from public.competition_teams where id=p_team_id and competition_id=p_competition_id and classroom_id=v_classroom_id) then raise exception 'Team does not belong to this competition'; end if;
 if p_assigned_to is null and p_assigned_role is null then raise exception 'Assign the task to a student or a role'; end if;
 if p_assigned_to is not null and not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=p_team_id and student_id=p_assigned_to) then raise exception 'Assigned student is not a member of this team'; end if;
 if p_assigned_role is not null and not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=p_team_id and operational_role=p_assigned_role) then raise exception 'The team does not have a member with that role'; end if;
 if char_length(trim(coalesce(p_title,''))) not between 3 and 140 then raise exception 'Task title must be 3-140 characters'; end if;
 if p_priority not in('low','normal','high','critical') then raise exception 'Invalid task priority'; end if;
 insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_to,assigned_role,title,description,priority,due_at,created_by)
 values(p_competition_id,p_team_id,v_classroom_id,p_assigned_to,p_assigned_role,trim(p_title),coalesce(p_description,''),p_priority,p_due_at,(select auth.uid()))
 returning id into v_id; return v_id;
end; $$;

create or replace function public.submit_competition_task(p_task_id uuid,p_submission jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_task public.competition_tasks%rowtype; v_role text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
 if v_task.status not in('pending','in_progress','rejected') then raise exception 'Task cannot be submitted in its current state'; end if;
 select operational_role into v_role from public.competition_team_members
 where competition_id=v_task.competition_id and team_id=v_task.team_id and student_id=(select auth.uid());
 if not found then raise exception 'You are not a member of this team'; end if;
 if v_task.assigned_to is not null and v_task.assigned_to<>(select auth.uid()) then raise exception 'This task is assigned to another student'; end if;
 if v_task.assigned_role is not null and v_task.assigned_role<>v_role then raise exception 'This task is assigned to another role'; end if;
 if jsonb_typeof(p_submission)<>'object' or length(p_submission::text)>12000 then raise exception 'Submission must be a JSON object under 12 KB'; end if;
 update public.competition_tasks set status='submitted',submission=p_submission,submitted_at=now() where id=p_task_id;
 return p_task_id;
end; $$;

create or replace function public.record_competition_decision(
 p_competition_id uuid,p_team_id uuid,p_domain text,p_decision_type text,
 p_selected_option text,p_rationale text,p_inputs jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_status text; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if v_status<>'active' then raise exception 'Competition is not active'; end if;
 if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=p_team_id and student_id=(select auth.uid())) then raise exception 'You are not a member of this team'; end if;
 if p_domain not in('procurement','inventory','production','transport','customer_service','finance','risk','strategy') then raise exception 'Unsupported decision domain'; end if;
 if char_length(trim(coalesce(p_decision_type,''))) not between 2 and 80 then raise exception 'Invalid decision type'; end if;
 if char_length(trim(coalesce(p_selected_option,''))) not between 1 and 120 then raise exception 'Select a valid option'; end if;
 if char_length(trim(coalesce(p_rationale,''))) not between 20 and 2000 then raise exception 'Explain your decision in at least 20 characters'; end if;
 if jsonb_typeof(coalesce(p_inputs,'{}'::jsonb))<>'object' then raise exception 'Decision inputs must be a JSON object'; end if;
 insert into public.competition_decisions(competition_id,team_id,classroom_id,student_id,domain,decision_type,selected_option,rationale,inputs)
 values(p_competition_id,p_team_id,v_classroom_id,(select auth.uid()),p_domain,trim(p_decision_type),trim(p_selected_option),trim(p_rationale),coalesce(p_inputs,'{}'::jsonb))
 returning id into v_id; return v_id;
end; $$;

create or replace function public.review_competition_task(p_task_id uuid,p_approved boolean,p_review_note text default '')
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_task public.competition_tasks%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_task from public.competition_tasks where id=p_task_id for update;
 if not found then raise exception 'Task not found'; end if;
 if not public.is_class_teacher(v_task.classroom_id) then raise exception 'Only the classroom teacher can review tasks'; end if;
 if v_task.status<>'submitted' then raise exception 'Only submitted tasks can be reviewed'; end if;
 update public.competition_tasks set status=case when p_approved then 'approved' else 'rejected' end,
 reviewed_by=(select auth.uid()),reviewed_at=now(),review_note=left(coalesce(p_review_note,''),1000) where id=p_task_id;
 return true;
end; $$;

create or replace function public.set_competition_status(p_competition_id uuid,p_status text)
returns text language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid; v_current text; v_team_count integer; v_member_count integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_current from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can control this competition'; end if;
 if p_status not in('active','paused','completed') then raise exception 'Invalid competition status'; end if;
 if p_status='active' and v_current='draft' then
  select count(*) into v_team_count from public.competition_teams where competition_id=p_competition_id;
  select count(*) into v_member_count from public.competition_team_members where competition_id=p_competition_id;
  if v_team_count<2 then raise exception 'Create at least two teams before starting'; end if;
  if v_member_count<2 then raise exception 'Assign students to teams before starting'; end if;
 end if;
 if v_current='completed' then raise exception 'Completed competitions cannot be reopened'; end if;
 if v_current='draft' and p_status<>'active' then raise exception 'A draft competition can only be started'; end if;
 update public.competitions set status=p_status,starts_at=case when p_status='active' and starts_at is null then now() else starts_at end,
 completed_at=case when p_status='completed' then now() else completed_at end where id=p_competition_id;
 return p_status;
end; $$;

revoke all on function public.is_competition_member(uuid) from public,anon;
grant execute on function public.is_competition_member(uuid) to authenticated;
revoke all on function public.is_competition_team_member(uuid,uuid) from public,anon;
grant execute on function public.is_competition_team_member(uuid,uuid) to authenticated;
revoke all on function public.create_competition(uuid,text,jsonb) from public,anon;
grant execute on function public.create_competition(uuid,text,jsonb) to authenticated;
revoke all on function public.create_competition_team(uuid,text,uuid) from public,anon;
grant execute on function public.create_competition_team(uuid,text,uuid) to authenticated;
revoke all on function public.assign_competition_member(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.assign_competition_member(uuid,uuid,uuid,text) to authenticated;
revoke all on function public.create_competition_task(uuid,uuid,text,text,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.create_competition_task(uuid,uuid,text,text,uuid,text,text,timestamptz) to authenticated;
revoke all on function public.submit_competition_task(uuid,jsonb) from public,anon;
grant execute on function public.submit_competition_task(uuid,jsonb) to authenticated;
revoke all on function public.record_competition_decision(uuid,uuid,text,text,text,text,jsonb) from public,anon;
grant execute on function public.record_competition_decision(uuid,uuid,text,text,text,text,jsonb) to authenticated;
revoke all on function public.review_competition_task(uuid,boolean,text) from public,anon;
grant execute on function public.review_competition_task(uuid,boolean,text) to authenticated;
revoke all on function public.set_competition_status(uuid,text) from public,anon;
grant execute on function public.set_competition_status(uuid,text) to authenticated;


-- Atomic round-robin team creation and role assignment for a balanced classroom split.
create or replace function public.create_balanced_competition_teams(p_competition_id uuid,p_team_count integer default 4)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_no integer; v_role_no integer;
 v_roles text[]:=array['procurement','manufacturer','warehouse','transport','operations'];
 v_idx integer:=0; v_student_assignments integer:=0;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then raise exception 'Teams already exist; use manual assignment instead'; end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_student_count<p_team_count then raise exception 'Not enough students to create balanced teams'; end if;
 for v_template in
  select id,name from public.company_templates where active order by
   case slug when 'lean-automotive' then 1 when 'omnichannel-retail' then 2 when 'flatpack-global' then 3 when 'beverage-fast-moving' then 4 else 5 end
  limit p_team_count
 loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Team '||v_created||' · '||v_template.name)
  returning id into v_team_ids[v_created];
  v_team_names:=array_append(v_team_names,'Team '||v_created||' · '||v_template.name);
 end loop;
 if v_created<>p_team_count then raise exception 'Not enough active company templates'; end if;
 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id order by joined_at,student_id
 loop
  v_idx:=v_member.rn;v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,'student_count',v_student_assignments,'team_names',to_jsonb(v_team_names));
end; $$;
revoke all on function public.create_balanced_competition_teams(uuid,integer) from public,anon;
grant execute on function public.create_balanced_competition_teams(uuid,integer) to authenticated;

create or replace function public.evaluate_competition_decision(p_decision_id uuid,p_score numeric,p_feedback text default '')
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_classroom_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id into v_classroom_id from public.competition_decisions where id=p_decision_id for update;
 if not found then raise exception 'Decision not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can evaluate decisions'; end if;
 if p_score is null or p_score<0 or p_score>100 then raise exception 'Score must be between 0 and 100'; end if;
 update public.competition_decisions set score=round(p_score,2),feedback=left(coalesce(p_feedback,''),2000),
 evaluated_by=(select auth.uid()),evaluated_at=now() where id=p_decision_id;
 return true;
end; $$;
revoke all on function public.evaluate_competition_decision(uuid,numeric,text) from public,anon;
grant execute on function public.evaluate_competition_decision(uuid,numeric,text) to authenticated;
