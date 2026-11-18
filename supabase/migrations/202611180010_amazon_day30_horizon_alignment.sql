
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_place_purchase_order(uuid,text,text,integer,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,'make_interval(days=>greatest(0,3-v_clock.current_round)*10+10)',
  'make_interval(days=>greatest(0,3-v_clock.current_round)*10+9)');
 execute v_def;
 select pg_get_functiondef('public.amazon_dispatch_shipment(uuid,integer,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,'make_interval(days=>(3-v_clock.current_round)*10+10)',
  'make_interval(days=>(3-v_clock.current_round)*10+9)');
 execute v_def;
 select pg_get_functiondef('public.initialize_competition_rounds()'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '  if new.settings->>''case_code''=''amazon-global-combined-crisis'' then
   update public.competition_rounds set',
  '  if new.settings->>''case_code''=''amazon-global-combined-crisis'' then
   update public.competition_customer_orders set due_at=now()+make_interval(days=case
    when order_number like ''%-R1'' then 9 when order_number like ''%-R2'' then 19 else 29 end)
   where competition_id=new.id and order_number like ''AMZ-%'';
   update public.competition_rounds set');
 execute v_def;
end $migration$;
