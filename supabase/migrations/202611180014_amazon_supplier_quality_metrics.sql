
alter table public.amazon_case_supplier_offers
 add column if not exists otif_pct numeric(5,2) not null default 90,
 add column if not exists defect_rate_pct numeric(5,2) not null default 2.5;

update public.amazon_case_supplier_offers set
 otif_pct=case supplier_code when 'SUP-A' then 90 when 'SUP-B' then 96 else 98 end,
 defect_rate_pct=case supplier_code when 'SUP-A' then 2.5 when 'SUP-B' then 1 else 0.5 end;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_get_case_data(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '''lead_time_days'',o.lead_time_days)',
  '''lead_time_days'',o.lead_time_days,''otif_pct'',o.otif_pct,''defect_rate_pct'',o.defect_rate_pct)');
 execute v_def;
end $migration$;
