
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_submit_approval(uuid,text,text,jsonb)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if p_approval_type=''strategy_change'' and coalesce(p_payload->>''posture'','''') not in (''cost_focused'',''balanced'',''service_focused'') then raise exception ''Invalid target procurement posture''; end if;',
  ' if p_approval_type=''strategy_change'' and coalesce(p_payload->>''posture'','''') not in (''cost_focused'',''balanced'',''service_focused'') then raise exception ''Invalid target procurement posture''; end if;
 if p_approval_type=''strategy_change'' and p_payload->>''posture''=''service_focused'' then
  raise exception ''Service-focused posture is infeasible: Suppliers B+C can cover at most 4,000 of 7,950 net required units (50.3%%), below the 60%% limit'';
 end if;');
 execute v_def;
end $migration$;
