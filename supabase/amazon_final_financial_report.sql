-- Amazon-only classroom simulation setup and locked final financial report.
-- Existing competition records and company templates are preserved.

create or replace function public.create_balanced_competition_teams(
 p_competition_id uuid,
 p_team_count integer default 4
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_classroom_id uuid;
 v_status text;
 v_student_count integer;
 v_created integer:=0;
 v_member record;
 v_team_ids uuid[]:='{}'::uuid[];
 v_team_names text[]:='{}'::text[];
 v_template record;
 v_team_id uuid;
 v_team_no integer;
 v_role_no integer;
 v_roles text[]:=array['procurement','supplier','manufacturer','warehouse','transport'];
 v_idx integer:=0;
 v_student_assignments integer:=0;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status into v_classroom_id,v_status
 from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then
  raise exception 'Teams already exist; use manual assignment instead';
 end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_student_count<p_team_count*5 then
  raise exception 'At least five students per team are required for all core operational roles';
 end if;
 select id,name into v_template from public.company_templates
 where slug='omnichannel-retail' and active;
 if not found then raise exception 'The active Amazon company template is missing'; end if;

 -- Every team receives the same Amazon operating model so results are comparable.
 for v_team_no in 1..p_team_count loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Amazon · Team '||v_created)
  returning id into v_team_id;
  v_team_ids:=array_append(v_team_ids,v_team_id);
  v_team_names:=array_append(v_team_names,'Amazon · Team '||v_created);
 end loop;

 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members
  where classroom_id=v_classroom_id
  order by joined_at,student_id
 loop
  v_idx:=v_member.rn;
  v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(
   competition_id,team_id,classroom_id,student_id,operational_role
  ) values(
   p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]
  );
  v_student_assignments:=v_student_assignments+1;
 end loop;

 return jsonb_build_object(
  'competition_id',p_competition_id,
  'team_count',v_created,
  'student_count',v_student_assignments,
  'company','Amazon',
  'team_names',to_jsonb(v_team_names)
 );
end;
$$;

revoke all on function public.create_balanced_competition_teams(uuid,integer) from public,anon;
grant execute on function public.create_balanced_competition_teams(uuid,integer) to authenticated;

-- Final report is only exposed after the teacher locks the completed simulation.
-- Profit is the simulation's operating surplus: delivered revenue less recorded
-- purchasing, production, transport and adjustment costs. It is not audited GAAP profit.
create or replace function public.get_competition_final_report(p_competition_id uuid)
returns table(
 team_id uuid,
 team_name text,
 company_name text,
 revenue numeric,
 operating_cost numeric,
 operating_profit numeric,
 profit_margin_pct numeric,
 return_on_capital_pct numeric,
 cash_balance numeric,
 starting_capital numeric,
 service_score numeric,
 inventory_score numeric,
 lead_time_score numeric,
 total_score numeric,
 score_coverage_pct numeric,
 delivered_orders integer,
 total_orders integer,
 avg_delivery_days numeric
)
language plpgsql
stable
security definer
set search_path=''
as $$
declare
 v_classroom_id uuid;
 v_status text;
 v_round_limit integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select c.classroom_id,c.status,clk.round_limit
 into v_classroom_id,v_status,v_round_limit
 from public.competitions c
 left join public.competition_simulation_clock clk on clk.competition_id=c.id
 where c.id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_member(v_classroom_id) then
  raise exception 'You are not a member of this classroom';
 end if;
 if v_status<>'completed' then
  raise exception 'The final financial report is available after the competition is completed';
 end if;
 if v_round_limit is null then raise exception 'Final simulation clock is missing'; end if;

 return query
 select
  m.team_id,
  m.team_name,
  m.company_name,
  coalesce(m.revenue,0)::numeric,
  coalesce(m.operating_cost,0)::numeric,
  (coalesce(m.revenue,0)-coalesce(m.operating_cost,0))::numeric,
  case when coalesce(m.revenue,0)>0
   then round(100*(m.revenue-m.operating_cost)/m.revenue,2)
   else null::numeric end,
  case when coalesce(m.starting_capital,0)>0
   then round(100*(m.revenue-m.operating_cost)/m.starting_capital,2)
   else null::numeric end,
  m.cash_balance,
  m.starting_capital,
  m.service_score,
  m.inventory_score,
  m.lead_time_score,
  coalesce(s.total_score,0)::numeric,
  coalesce((s.metrics->>'coverage_pct')::numeric,m.score_coverage_pct),
  m.delivered_orders,
  m.total_orders,
  m.avg_delivery_days
 from public.competition_team_live_metrics m
 left join public.competition_score_snapshots s
  on s.competition_id=m.competition_id
  and s.team_id=m.team_id
  and s.round_number=v_round_limit
 where m.competition_id=p_competition_id
 order by coalesce(s.total_score,0) desc,m.team_name;
end;
$$;

revoke all on function public.get_competition_final_report(uuid) from public,anon;
grant execute on function public.get_competition_final_report(uuid) to authenticated;
