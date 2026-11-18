
create table if not exists public.amazon_case_quality_receipts (
 id uuid primary key default gen_random_uuid(),
 purchase_order_id uuid not null references public.competition_purchase_orders(id) on delete cascade,
 team_id uuid not null references public.competition_teams(id) on delete cascade,
 supplier_code text not null,
 sku text not null,
 received_quantity integer not null,
 defective_quantity integer not null,
 usable_quantity integer not null,
 defect_rate_pct numeric(5,2) not null,
 created_at timestamptz not null default now()
);
alter table public.amazon_case_quality_receipts enable row level security;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' v_new integer; v_stock integer; v_cost numeric; v_item text; v_capacity integer; v_occupied integer;',
  ' v_new integer; v_stock integer; v_cost numeric; v_item text; v_capacity integer; v_occupied integer;
 v_defect_rate numeric; v_defective integer; v_usable integer; v_supplier_code text;');
 v_def:=replace(v_def,
  ' select item_name into v_item from public.amazon_case_skus where sku=v_po.sku;',
  ' select item_name into v_item from public.amazon_case_skus where sku=v_po.sku;
 select defect_rate_pct,supplier_code into v_defect_rate,v_supplier_code
 from public.amazon_case_supplier_offers where team_id=v_po.team_id and supplier_id=v_po.supplier_id and sku=v_po.sku;
 v_defective:=least(p_quantity,ceil(p_quantity*coalesce(v_defect_rate,0)/100.0)::integer);
 v_usable:=p_quantity-v_defective;');
 v_def:=replace(v_def,
  'values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_item,''finished_goods'',p_quantity,0,v_po.unit_cost)',
  'values(v_po.competition_id,v_po.team_id,v_po.classroom_id,v_po.sku,v_item,''finished_goods'',v_usable,0,v_po.unit_cost)');
 v_def:=replace(v_def,
  'public.competition_inventory.quantity+excluded.quantity>0 then
   round((public.competition_inventory.quantity*public.competition_inventory.unit_cost+excluded.quantity*excluded.unit_cost)/
   (public.competition_inventory.quantity+excluded.quantity),2)',
  'public.competition_inventory.quantity+excluded.quantity>0 then
   round((public.competition_inventory.quantity*public.competition_inventory.unit_cost+excluded.quantity*excluded.unit_cost)/
   (public.competition_inventory.quantity+excluded.quantity),2)');
 v_def:=replace(v_def,
  ' update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;',
  ' insert into public.amazon_case_quality_receipts(purchase_order_id,team_id,supplier_code,sku,received_quantity,defective_quantity,usable_quantity,defect_rate_pct)
 values(p_purchase_order_id,v_po.team_id,v_supplier_code,v_po.sku,p_quantity,v_defective,v_usable,coalesce(v_defect_rate,0));
 update public.competition_teams set cash_balance=cash_balance-v_cost where id=v_po.team_id;');
 v_def:=replace(v_def,
  'jsonb_build_object(''stock_after'',v_stock,''cost'',v_cost,''po_id'',p_purchase_order_id,''virtual_received_at'',v_clock.virtual_now));',
  'jsonb_build_object(''stock_after'',v_stock,''cost'',v_cost,''po_id'',p_purchase_order_id,''virtual_received_at'',v_clock.virtual_now,
   ''received_quantity'',p_quantity,''usable_quantity'',v_usable,''defective_quantity'',v_defective,''defect_rate_pct'',v_defect_rate));');
 v_def:=replace(v_def,
  'return jsonb_build_object(''received_quantity'',v_new,''stock_quantity'',v_stock,''cost'',v_cost);',
  'return jsonb_build_object(''received_quantity'',v_new,''stock_quantity'',v_stock,''cost'',v_cost,
   ''usable_quantity'',v_usable,''defective_quantity'',v_defective,''defect_rate_pct'',v_defect_rate);');
 execute v_def;
end $migration$;
