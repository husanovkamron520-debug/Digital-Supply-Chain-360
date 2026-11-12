-- SupplyChain14 supplier account linking and purchase-order response workflow
-- Applied to Supabase project otkdwzvzsqhzicwbaeng on 2026-11-12.

alter table public.suppliers
  add column if not exists supplier_user_id uuid references public.profiles(id) on delete set null;

create unique index if not exists suppliers_class_supplier_user_uidx
  on public.suppliers(classroom_id, supplier_user_id)
  where supplier_user_id is not null;

create index if not exists suppliers_supplier_user_id_idx
  on public.suppliers(supplier_user_id)
  where supplier_user_id is not null;

alter table public.purchase_orders
  add column if not exists supplier_response text not null default 'pending'
    check (supplier_response in ('pending','accepted','rejected')),
  add column if not exists supplier_note text,
  add column if not exists supplier_responded_at timestamptz;

create or replace function public.create_supplier(
  p_classroom_id uuid, p_supplier_code text, p_name text, p_lead_time_days integer default 7
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_id uuid;
  v_role text;
  v_code text := upper(trim(coalesce(p_supplier_code,'')));
  v_name text := trim(coalesce(p_name,''));
  v_supplier_user_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
  if not public.is_class_teacher(p_classroom_id) then
    select operational_role into v_role from public.classroom_members
    where classroom_id=p_classroom_id and student_id=(select auth.uid());
    if v_role is distinct from 'supplier' then
      raise exception 'Only the teacher or assigned Supplier role can manage supplier records';
    end if;
    v_supplier_user_id := (select auth.uid());
  end if;
  if char_length(v_code) not between 2 and 30 then raise exception 'Supplier code must be 2-30 characters'; end if;
  if char_length(v_name) not between 2 and 120 then raise exception 'Supplier name must be 2-120 characters'; end if;
  if p_lead_time_days is null or p_lead_time_days not between 0 and 365 then raise exception 'Lead time must be 0-365 days'; end if;
  insert into public.suppliers(classroom_id,supplier_code,name,lead_time_days,created_by,supplier_user_id)
  values(p_classroom_id,v_code,v_name,p_lead_time_days,(select auth.uid()),v_supplier_user_id)
  returning id into v_id;
  insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
  values(p_classroom_id,(select auth.uid()),'supplier_created','Supplier added: '||v_code,
    jsonb_build_object('supplier_id',v_id,'supplier_code',v_code,'lead_time_days',p_lead_time_days,'supplier_user_id',v_supplier_user_id));
  return v_id;
exception when unique_violation then
  raise exception 'Supplier code already exists, or your account already has a supplier profile in this classroom';
end;
$$;

create or replace function public.respond_to_purchase_order(
  p_purchase_order_id uuid, p_response text, p_note text default null
) returns boolean
language plpgsql security definer set search_path=''
as $$
declare
  v_po public.purchase_orders%rowtype;
  v_supplier_user_id uuid;
  v_role text;
  v_response text := lower(trim(coalesce(p_response,'')));
  v_note text := trim(coalesce(p_note,''));
begin
  if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
  if v_response not in ('accepted','rejected') then raise exception 'Response must be accepted or rejected'; end if;
  if char_length(v_note)>500 then raise exception 'Supplier note must be 500 characters or fewer'; end if;
  select * into v_po from public.purchase_orders where id=p_purchase_order_id for update;
  if not found then raise exception 'Purchase order not found'; end if;
  select supplier_user_id into v_supplier_user_id from public.suppliers
    where id=v_po.supplier_id and classroom_id=v_po.classroom_id;
  select operational_role into v_role from public.classroom_members
    where classroom_id=v_po.classroom_id and student_id=(select auth.uid());
  if v_role is distinct from 'supplier' or v_supplier_user_id is distinct from (select auth.uid()) then
    raise exception 'Only the assigned supplier account can respond to this purchase order';
  end if;
  if v_po.status<>'placed' then raise exception 'Only placed purchase orders can receive a supplier response'; end if;
  if v_po.supplier_response<>'pending' then raise exception 'A supplier response has already been submitted'; end if;
  update public.purchase_orders set supplier_response=v_response,
    supplier_note=nullif(v_note,''),supplier_responded_at=now()
  where id=p_purchase_order_id;
  insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
  values(v_po.classroom_id,(select auth.uid()),
    case when v_response='accepted' then 'purchase_order_accepted_by_supplier' else 'purchase_order_rejected_by_supplier' end,
    'Supplier '||v_response||' purchase order '||v_po.po_number,
    jsonb_build_object('purchase_order_id',p_purchase_order_id,'supplier_id',v_po.supplier_id,'response',v_response,'note',nullif(v_note,'')));
  return true;
end;
$$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_po public.purchase_orders%rowtype; v_role text; v_new_received integer; v_stock integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.purchase_orders where id=p_purchase_order_id for update;
 if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_class_teacher(v_po.classroom_id) then
   select operational_role into v_role from public.classroom_members where classroom_id=v_po.classroom_id and student_id=(select auth.uid());
   if v_role is distinct from 'warehouse' then raise exception 'Only the teacher or assigned Warehouse Manager can receive purchase orders'; end if;
 end if;
 if v_po.status='cancelled' then raise exception 'Cancelled purchase orders cannot be received'; end if;
 if v_po.supplier_response='rejected' then raise exception 'The supplier rejected this purchase order'; end if;
 if v_po.supplier_response='pending' and not public.is_class_teacher(v_po.classroom_id) then
   raise exception 'The supplier must accept the purchase order before warehouse receipt';
 end if;
 if p_quantity is null or p_quantity<1 then raise exception 'Receive quantity must be at least one'; end if;
 if v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Receive quantity exceeds the outstanding balance'; end if;
 insert into public.inventory(classroom_id,scenario_id,sku,item_name,quantity,reorder_level)
 values(v_po.classroom_id,null,v_po.sku,v_po.item_name,p_quantity,0)
 on conflict(classroom_id,sku) where scenario_id is null
 do update set quantity=inventory.quantity+excluded.quantity,updated_at=now()
 returning quantity into v_stock;
 v_new_received:=v_po.received_quantity+p_quantity;
 update public.purchase_orders set received_quantity=v_new_received,
   status=case when v_new_received=quantity then 'received' else 'partially_received' end
 where id=p_purchase_order_id;
 insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
 values(v_po.classroom_id,(select auth.uid()),'purchase_order_received',
   'Received '||p_quantity||' units against '||v_po.po_number,
   jsonb_build_object('purchase_order_id',p_purchase_order_id,'sku',v_po.sku,'received_now',p_quantity,
     'received_total',v_new_received,'stock_after',v_stock));
 return jsonb_build_object('received_quantity',v_new_received,'ordered_quantity',v_po.quantity,
   'stock_quantity',v_stock,'status',case when v_new_received=v_po.quantity then 'received' else 'partially_received' end);
end;
$$;

revoke all on function public.respond_to_purchase_order(uuid,text,text) from public,anon;
grant execute on function public.respond_to_purchase_order(uuid,text,text) to authenticated;
