
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_get_case_data(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '  ''approvals'',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),''[]''::jsonb) from public.amazon_case_approvals a where a.team_id=p_team_id and a.status=''pending'')',
  '  ''fulfilment'',(select coalesce(jsonb_agg(jsonb_build_object(''order_id'',f.order_id,''ready_quantity'',f.ready_quantity,''updated_round'',f.updated_round)),''[]''::jsonb) from public.amazon_case_fulfillment f where f.team_id=p_team_id),
  ''approvals'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',a.id,''approval_type'',a.approval_type,''reason'',a.reason,''payload'',a.payload,''requested_by'',a.requested_by,''status'',a.status,
   ''approve_votes'',(select count(*) from public.amazon_case_approval_votes v where v.approval_id=a.id and v.vote=''approve''),
   ''reject_votes'',(select count(*) from public.amazon_case_approval_votes v where v.approval_id=a.id and v.vote=''reject''))),''[]''::jsonb) from public.amazon_case_approvals a where a.team_id=p_team_id and a.status=''pending'')');
 execute v_def;
end $migration$;
