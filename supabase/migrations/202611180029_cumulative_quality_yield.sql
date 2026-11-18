
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'v_defect_rate numeric; v_defective integer; v_usable integer; v_supplier_code text;',
  'v_defect_rate numeric; v_defective integer; v_usable integer; v_supplier_code text; v_prior_defective integer;');
 v_def:=replace(v_def,
  'v_defective:=least(p_quantity,ceil(p_quantity*coalesce(v_defect_rate,0)/100.0)::integer);',
  'v_prior_defective:=ceil(v_po.received_quantity*coalesce(v_defect_rate,0)/100.0)::integer;
 v_defective:=least(p_quantity,greatest(0,ceil((v_po.received_quantity+p_quantity)*coalesce(v_defect_rate,0)/100.0)::integer-v_prior_defective));');
 execute v_def;
end $migration$;
