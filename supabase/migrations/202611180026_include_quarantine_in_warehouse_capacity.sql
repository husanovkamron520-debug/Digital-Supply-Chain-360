
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'select coalesce(sum(quantity),0) into v_occupied from public.competition_inventory where team_id=v_po.team_id;',
  'select coalesce((select sum(quantity) from public.competition_inventory where team_id=v_po.team_id),0)
   +coalesce((select sum(defective_quantity) from public.amazon_case_quality_receipts where team_id=v_po.team_id),0)
  into v_occupied;');
 execute v_def;
end $migration$;
