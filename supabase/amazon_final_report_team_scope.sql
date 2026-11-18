-- Limit detailed final financial results to teachers and each student's own team.
-- The public leaderboard remains aggregate; competitors cannot inspect another team's finances.

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
  and (
   public.is_class_teacher(v_classroom_id)
   or exists(
    select 1 from public.competition_team_members tm
    where tm.competition_id=p_competition_id
     and tm.team_id=m.team_id
     and tm.student_id=(select auth.uid())
   )
  )
 order by coalesce(s.total_score,0) desc,m.team_name;
end;
$$;

revoke all on function public.get_competition_final_report(uuid) from public,anon;
grant execute on function public.get_competition_final_report(uuid) to authenticated;
