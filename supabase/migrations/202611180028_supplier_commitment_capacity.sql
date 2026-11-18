
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_record_supplier_commitment(uuid,text,text,integer,integer,text,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'v_offer public.amazon_case_supplier_offers%rowtype; v_id uuid; v_min_day integer;',
  'v_offer public.amazon_case_supplier_offers%rowtype; v_id uuid; v_min_day integer; v_existing integer;');
 v_def:=replace(v_def,
  'if p_quantity is null or p_quantity<1 or p_quantity>v_offer.max_capacity then raise exception ''Commitment quantity exceeds supplier SKU capacity''; end if;',
  'if p_quantity is null or p_quantity<1 then raise exception ''Commitment quantity must be positive''; end if;
 select coalesce(sum(committed_quantity),0) into v_existing from public.amazon_case_supplier_commitments
 where team_id=p_team_id and supplier_code=p_supplier_code and sku=upper(p_sku);
 if v_existing+p_quantity>v_offer.max_capacity then raise exception ''Total supplier commitments exceed this SKU capacity; remaining capacity % units'',greatest(0,v_offer.max_capacity-v_existing); end if;');
 execute v_def;
end $migration$;
