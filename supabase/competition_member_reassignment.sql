CREATE OR REPLACE FUNCTION public.update_competition_member_assignment(
 p_membership_id uuid,
 p_target_team_id uuid,
 p_operational_role text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
 v_competition_id uuid;
 v_classroom_id uuid;
 v_status text;
 v_member public.competition_team_members%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;

 select competition_id into v_competition_id
 from public.competition_team_members where id=p_membership_id;
 if not found then raise exception 'Team member assignment not found'; end if;

 -- Lock the competition before changing membership, so start cannot race with reassignment.
 select classroom_id,status into v_classroom_id,v_status
 from public.competitions where id=v_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can change team assignments'; end if;
 if v_status<>'draft' then raise exception 'Team assignments are locked after competition starts'; end if;

 select * into v_member from public.competition_team_members
 where id=p_membership_id for update;
 if not found or v_member.competition_id<>v_competition_id then
  raise exception 'Team member assignment changed; refresh and try again';
 end if;
 if p_operational_role not in ('procurement','supplier','manufacturer','warehouse','transport','retailer','customer','operations','finance','analyst') then
  raise exception 'Unsupported operational role';
 end if;
 if not exists(
  select 1 from public.competition_teams
  where id=p_target_team_id and competition_id=v_competition_id and classroom_id=v_classroom_id
 ) then raise exception 'Target team does not belong to this competition'; end if;

 update public.competition_team_members
 set team_id=p_target_team_id,operational_role=p_operational_role
 where id=p_membership_id;
 return p_membership_id;
end;
$function$;

revoke all on function public.update_competition_member_assignment(uuid,uuid,text) from public,anon;
grant execute on function public.update_competition_member_assignment(uuid,uuid,text) to authenticated;