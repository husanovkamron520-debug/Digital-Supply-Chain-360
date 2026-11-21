grant select on table public.amazon_case_fulfillment to authenticated;

drop policy if exists amazon_case_fulfillment_read_team_scope on public.amazon_case_fulfillment;
create policy amazon_case_fulfillment_read_team_scope
on public.amazon_case_fulfillment
for select
to authenticated
using (
  exists (
    select 1
    from public.competition_teams t
    where t.id = amazon_case_fulfillment.team_id
      and (
        public.is_class_teacher(t.classroom_id)
        or private.is_competition_team_member(t.id)
      )
  )
);
