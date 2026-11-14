-- Balanced assignment requires five students per team so every team can cover all core roles.
CREATE OR REPLACE FUNCTION public.create_balanced_competition_teams(p_competition_id uuid, p_team_count integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_id uuid; v_team_no integer; v_role_no integer;
 v_roles text[]:=array['procurement','supplier','manufacturer','warehouse','transport'];
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
 if v_student_count<p_team_count*5 then raise exception 'At least five students per team are required for all core operational roles'; end if;
 for v_template in
  select id,name from public.company_templates where active order by
   case slug when 'lean-automotive' then 1 when 'omnichannel-retail' then 2 when 'flatpack-global' then 3 when 'beverage-fast-moving' then 4 else 5 end
  limit p_team_count
 loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,'Team '||v_created||' · '||v_template.name)
  returning id into v_team_id;
  v_team_ids:=array_append(v_team_ids,v_team_id);
  v_team_names:=array_append(v_team_names,'Team '||v_created||' · '||v_template.name);
 end loop;
 if v_created<>p_team_count then raise exception 'Not enough active company templates'; end if;
 for v_member in
  select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id order by joined_at,student_id
 loop
  v_idx:=v_member.rn;
  v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,'student_count',v_student_assignments,'team_names',to_jsonb(v_team_names));
end; $function$
;
revoke all on function public.create_balanced_competition_teams(uuid,integer) from public,anon;
grant execute on function public.create_balanced_competition_teams(uuid,integer) to authenticated;
