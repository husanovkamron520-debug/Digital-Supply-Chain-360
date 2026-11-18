
alter table public.amazon_case_quality_receipts add column if not exists competition_id uuid references public.competitions(id) on delete cascade;
update public.amazon_case_quality_receipts qr set competition_id=t.competition_id from public.competition_teams t where t.id=qr.team_id and qr.competition_id is null;
alter table public.amazon_case_quality_receipts alter column competition_id set not null;
alter table public.amazon_case_quality_receipts
 add column if not exists disposed_quantity integer not null default 0
 check (disposed_quantity>=0 and disposed_quantity<=defective_quantity);

create or replace function public.amazon_dispose_defects(p_quality_receipt_id uuid,p_quantity integer,p_reason text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_receipt public.amazon_case_quality_receipts%rowtype; v_remaining integer; v_new integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_receipt from public.amazon_case_quality_receipts where id=p_quality_receipt_id for update;
 if not found then raise exception 'Quality receipt not found'; end if;
 if not exists(select 1 from public.competitions c where c.id=v_receipt.competition_id and c.settings->>'case_code'='amazon-global-combined-crisis' and c.status='active') then raise exception 'Amazon case is not active'; end if;
 if not public.is_competition_role(v_receipt.competition_id,v_receipt.team_id,array['warehouse']) then raise exception 'Only Warehouse Manager can clear quarantine stock'; end if;
 v_remaining:=v_receipt.defective_quantity-v_receipt.disposed_quantity;
 if p_quantity is null or p_quantity<1 or p_quantity>v_remaining then raise exception 'Disposal quantity exceeds remaining quarantine stock'; end if;
 if char_length(trim(coalesce(p_reason,'')))<8 then raise exception 'Record a reason for disposal or supplier return'; end if;
 v_new:=v_receipt.disposed_quantity+p_quantity;
 update public.amazon_case_quality_receipts set disposed_quantity=v_new where id=p_quality_receipt_id;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 select c.id,v_receipt.team_id,t.classroom_id,(select auth.uid()),'warehouse','amazon_quality_disposed',
  'Defective units removed from quarantine',jsonb_build_object('quality_receipt_id',p_quality_receipt_id,'quantity',p_quantity,'reason',trim(p_reason))
 from public.competitions c join public.competition_teams t on t.id=v_receipt.team_id where c.id=v_receipt.competition_id;
 return jsonb_build_object('disposed_quantity',v_new,'remaining_quarantine',v_receipt.defective_quantity-v_new);
end; $$;
grant execute on function public.amazon_dispose_defects(uuid,integer,text) to authenticated;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'insert into public.amazon_case_quality_receipts(purchase_order_id,team_id,supplier_code,sku,received_quantity,defective_quantity,usable_quantity,defect_rate_pct)
 values(p_purchase_order_id,v_po.team_id,v_supplier_code,v_po.sku,p_quantity,v_defective,v_usable,coalesce(v_defect_rate,0));',
  'insert into public.amazon_case_quality_receipts(purchase_order_id,competition_id,team_id,supplier_code,sku,received_quantity,defective_quantity,usable_quantity,defect_rate_pct)
 values(p_purchase_order_id,v_po.competition_id,v_po.team_id,v_supplier_code,v_po.sku,p_quantity,v_defective,v_usable,coalesce(v_defect_rate,0));');
 v_def:=replace(v_def,
  'select sum(defective_quantity) from public.amazon_case_quality_receipts where team_id=v_po.team_id',
  'select sum(defective_quantity-disposed_quantity) from public.amazon_case_quality_receipts where team_id=v_po.team_id');
 execute v_def;
 select pg_get_functiondef('public.amazon_get_case_data(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '''commitments'',(select coalesce(jsonb_agg(to_jsonb(sc) order by sc.created_at desc),''[]''::jsonb) from public.amazon_case_supplier_commitments sc where sc.team_id=p_team_id),',
  '''quality_receipts'',(select coalesce(jsonb_agg(to_jsonb(qr) order by qr.created_at desc),''[]''::jsonb) from public.amazon_case_quality_receipts qr where qr.team_id=p_team_id),
  ''commitments'',(select coalesce(jsonb_agg(to_jsonb(sc) order by sc.created_at desc),''[]''::jsonb) from public.amazon_case_supplier_commitments sc where sc.team_id=p_team_id),');
 execute v_def;
end $migration$;
