
alter table public.amazon_case_fulfillment
 add column if not exists round_released_quantity integer not null default 0;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_fulfill_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'select coalesce(sum(f.ready_quantity),0) into v_round_total from public.amazon_case_fulfillment f',
  'select coalesce(sum(f.round_released_quantity),0) into v_round_total from public.amazon_case_fulfillment f');
 v_def:=replace(v_def,
  'insert into public.amazon_case_fulfillment(order_id,team_id,ready_quantity,updated_round)
 values(p_order_id,v_order.team_id,p_quantity,v_clock.current_round)
 on conflict(order_id) do update set ready_quantity=amazon_case_fulfillment.ready_quantity+excluded.ready_quantity,
 updated_round=excluded.updated_round,updated_at=now();',
  'insert into public.amazon_case_fulfillment(order_id,team_id,ready_quantity,updated_round,round_released_quantity)
 values(p_order_id,v_order.team_id,p_quantity,v_clock.current_round,p_quantity)
 on conflict(order_id) do update set ready_quantity=amazon_case_fulfillment.ready_quantity+excluded.ready_quantity,
 round_released_quantity=case when amazon_case_fulfillment.updated_round=excluded.updated_round
  then amazon_case_fulfillment.round_released_quantity+excluded.round_released_quantity else excluded.round_released_quantity end,
 updated_round=excluded.updated_round,updated_at=now();');
 execute v_def;

 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not exists(select 1 from public.competitions c where c.id=v_po.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case purchase order''; end if;',
  ' if not exists(select 1 from public.competitions c where c.id=v_po.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'' and c.status=''active'') then raise exception ''Amazon case is not active''; end if;
 if v_po.status in (''cancelled'',''received'') then raise exception ''This purchase order cannot be received''; end if;');
 v_def:=replace(v_def,
  'on conflict(team_id,sku) do update set quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()',
  'on conflict(team_id,sku) do update set
  unit_cost=case when public.competition_inventory.quantity+excluded.quantity>0 then
   round((public.competition_inventory.quantity*public.competition_inventory.unit_cost+excluded.quantity*excluded.unit_cost)/
   (public.competition_inventory.quantity+excluded.quantity),2) else excluded.unit_cost end,
  quantity=public.competition_inventory.quantity+excluded.quantity,updated_at=now()');
 execute v_def;

 select pg_get_functiondef('public.amazon_submit_approval(uuid,text,text,jsonb)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'values(v_team.competition_id,p_team_id,(select auth.uid()),p_approval_type,trim(p_reason),coalesce(p_payload,''{}''::jsonb)) returning id into v_id;',
  'values(v_team.competition_id,p_team_id,(select auth.uid()),p_approval_type,trim(p_reason),
  case when p_approval_type=''strategy_change'' then
   coalesce(p_payload,''{}''::jsonb)||jsonb_build_object(''previous_posture'',
    (select strategic_posture from public.amazon_case_team_state where team_id=p_team_id),
    ''affected_roles'',jsonb_build_array(''supplier'',''warehouse'',''transport''))
   else coalesce(p_payload,''{}''::jsonb) end) returning id into v_id;');
 execute v_def;

 select pg_get_functiondef('public.amazon_vote_approval(uuid,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' return jsonb_build_object(''status'',(select status from public.amazon_case_approvals where id=p_approval_id),''approve_votes'',v_yes,''reject_votes'',v_no,''affected_roles_pending'',v_missing);',
  ' insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
  select v_a.competition_id,v_a.team_id,t.classroom_id,(select auth.uid()),''approval'',''amazon_approval_vote'',
   ''Team member voted on approval request'',jsonb_build_object(''approval_id'',p_approval_id,''vote'',p_vote,
    ''status'',(select status from public.amazon_case_approvals where id=p_approval_id),''approve_votes'',v_yes,''reject_votes'',v_no)
  from public.competition_teams t where t.id=v_a.team_id;
 return jsonb_build_object(''status'',(select status from public.amazon_case_approvals where id=p_approval_id),''approve_votes'',v_yes,''reject_votes'',v_no,''affected_roles_pending'',v_missing);');
 execute v_def;
end $migration$;
