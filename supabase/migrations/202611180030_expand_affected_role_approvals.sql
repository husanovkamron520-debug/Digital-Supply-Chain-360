
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_submit_approval(uuid,text,text,jsonb)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'case when p_approval_type=''strategy_change'' then
   coalesce(p_payload,''{}''::jsonb)||jsonb_build_object(''previous_posture'',
    (select strategic_posture from public.amazon_case_team_state where team_id=p_team_id),
    ''affected_roles'',jsonb_build_array(''supplier'',''warehouse'',''transport''))
   else coalesce(p_payload,''{}''::jsonb) end',
  'case when p_approval_type=''strategy_change'' then
   coalesce(p_payload,''{}''::jsonb)||jsonb_build_object(''previous_posture'',
    (select strategic_posture from public.amazon_case_team_state where team_id=p_team_id),
    ''affected_roles'',jsonb_build_array(''supplier'',''warehouse'',''manufacturer'',''transport''))
   when p_approval_type=''reserve_draw'' then
   coalesce(p_payload,''{}''::jsonb)||jsonb_build_object(''affected_roles'',jsonb_build_array(''warehouse'',''manufacturer'',''transport''))
   else coalesce(p_payload,''{}''::jsonb) end');
 execute v_def;
end $migration$;
