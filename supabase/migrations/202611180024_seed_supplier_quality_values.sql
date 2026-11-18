
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_initialize_team(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'insert into public.amazon_case_supplier_offers(team_id,supplier_id,supplier_code,sku,unit_price,moq,max_capacity,lead_time_days)',
  'insert into public.amazon_case_supplier_offers(team_id,supplier_id,supplier_code,sku,unit_price,moq,max_capacity,lead_time_days,otif_pct,defect_rate_pct)');
 v_def:=replace(v_def,
  'else 550 end,22),',
  'else 550 end,22,90,2.5),');
 v_def:=replace(v_def,
  'else 150 end,8),',
  'else 150 end,8,96,1),');
 v_def:=replace(v_def,
  'else 100 end,5);',
  'else 100 end,5,98,0.5);');
 execute v_def;
end $migration$;
