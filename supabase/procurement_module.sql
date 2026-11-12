-- SupplyChain14 supplier and procurement module (idempotent migration)
create table if not exists public.suppliers (
 id uuid primary key default gen_random_uuid(), classroom_id uuid not null references public.classrooms(id) on delete cascade,
 supplier_code text not null,name text not null,lead_time_days integer not null default 7 check(lead_time_days between 0 and 365),
 status text not null default 'active' check(status in ('active','inactive')),created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),unique(classroom_id,supplier_code)
);
create table if not exists public.purchase_orders (
 id uuid primary key default gen_random_uuid(),classroom_id uuid not null references public.classrooms(id) on delete cascade,
 supplier_id uuid not null references public.suppliers(id),created_by uuid not null references public.profiles(id),
 po_number text not null,sku text not null,item_name text not null,quantity integer not null check(quantity between 1 and 1000000),
 received_quantity integer not null default 0 check(received_quantity>=0 and received_quantity<=quantity),
 unit_cost numeric(14,2) not null default 0 check(unit_cost>=0),status text not null default 'placed'
 check(status in ('placed','partially_received','received','cancelled')),expected_at timestamptz,created_at timestamptz not null default now(),
 unique(classroom_id,po_number)
);
create index if not exists suppliers_classroom_idx on public.suppliers(classroom_id,name);
create index if not exists purchase_orders_classroom_idx on public.purchase_orders(classroom_id,created_at desc);
alter table public.suppliers enable row level security; alter table public.purchase_orders enable row level security;
drop policy if exists suppliers_select_members on public.suppliers;
create policy suppliers_select_members on public.suppliers for select to authenticated using(public.is_class_member(classroom_id));
drop policy if exists purchase_orders_select_members on public.purchase_orders;
create policy purchase_orders_select_members on public.purchase_orders for select to authenticated using(public.is_class_member(classroom_id));
revoke all on public.suppliers,public.purchase_orders from public,anon,authenticated;
grant select on public.suppliers,public.purchase_orders to authenticated;

create or replace function public.create_supplier(p_classroom_id uuid,p_supplier_code text,p_name text,p_lead_time_days integer default 7)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_role text; v_code text:=upper(trim(coalesce(p_supplier_code,''))); v_name text:=trim(coalesce(p_name,''));
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then select operational_role into v_role from public.classroom_members where classroom_id=p_classroom_id and student_id=(select auth.uid()); if v_role is distinct from 'supplier' then raise exception 'Only the teacher or assigned Supplier role can manage supplier records'; end if; end if;
 if char_length(v_code) not between 2 and 30 then raise exception 'Supplier code must be 2-30 characters'; end if;
 if char_length(v_name) not between 2 and 120 then raise exception 'Supplier name must be 2-120 characters'; end if;
 if p_lead_time_days is null or p_lead_time_days not between 0 and 365 then raise exception 'Lead time must be 0-365 days'; end if;
 insert into public.suppliers(classroom_id,supplier_code,name,lead_time_days,created_by) values(p_classroom_id,v_code,v_name,p_lead_time_days,(select auth.uid())) returning id into v_id;
 insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata) values(p_classroom_id,(select auth.uid()),'supplier_created','Supplier added: '||v_code,jsonb_build_object('supplier_id',v_id,'supplier_code',v_code,'lead_time_days',p_lead_time_days)); return v_id;
exception when unique_violation then raise exception 'Supplier code already exists in this classroom'; end; $$;

create or replace function public.create_purchase_order(p_classroom_id uuid,p_supplier_id uuid,p_po_number text,p_sku text,p_item_name text,p_quantity integer,p_unit_cost numeric default 0,p_expected_at timestamptz default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_role text; v_po text:=upper(trim(coalesce(p_po_number,''))); v_sku text:=upper(trim(coalesce(p_sku,''))); v_item text:=trim(coalesce(p_item_name,''));
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then select operational_role into v_role from public.classroom_members where classroom_id=p_classroom_id and student_id=(select auth.uid()); if v_role is distinct from 'manufacturer' then raise exception 'Only the teacher or assigned Manufacturer role can create purchase orders'; end if; end if;
 if not exists(select 1 from public.suppliers where id=p_supplier_id and classroom_id=p_classroom_id and status='active') then raise exception 'Active supplier not found in this classroom'; end if;
 if char_length(v_po) not between 3 and 40 then raise exception 'PO number must be 3-40 characters'; end if;
 if char_length(v_sku) not between 2 and 40 then raise exception 'SKU must be 2-40 characters'; end if;
 if char_length(v_item) not between 2 and 120 then raise exception 'Item name must be 2-120 characters'; end if;
 if p_quantity is null or p_quantity not between 1 and 1000000 then raise exception 'Quantity must be 1-1,000,000'; end if;
 if p_unit_cost is null or p_unit_cost<0 or p_unit_cost>100000000 then raise exception 'Unit cost is outside the allowed range'; end if;
 if p_expected_at is not null and p_expected_at<now()-interval '1 day' then raise exception 'Expected date is too far in the past'; end if;
 insert into public.purchase_orders(classroom_id,supplier_id,created_by,po_number,sku,item_name,quantity,unit_cost,expected_at) values(p_classroom_id,p_supplier_id,(select auth.uid()),v_po,v_sku,v_item,p_quantity,p_unit_cost,p_expected_at) returning id into v_id;
 insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata) values(p_classroom_id,(select auth.uid()),'purchase_order_created','Purchase order '||v_po||' created',jsonb_build_object('purchase_order_id',v_id,'sku',v_sku,'quantity',p_quantity)); return v_id;
exception when unique_violation then raise exception 'Purchase order number already exists in this classroom'; end; $$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_quantity integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_po public.purchase_orders%rowtype; v_role text; v_new_received integer; v_stock integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.purchase_orders where id=p_purchase_order_id for update; if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_class_teacher(v_po.classroom_id) then select operational_role into v_role from public.classroom_members where classroom_id=v_po.classroom_id and student_id=(select auth.uid()); if v_role is distinct from 'warehouse' then raise exception 'Only the teacher or assigned Warehouse Manager can receive purchase orders'; end if; end if;
 if v_po.status='cancelled' then raise exception 'Cancelled purchase orders cannot be received'; end if;
 if p_quantity is null or p_quantity<1 then raise exception 'Receive quantity must be at least one'; end if;
 if v_po.received_quantity+p_quantity>v_po.quantity then raise exception 'Receive quantity exceeds the outstanding balance'; end if;
 insert into public.inventory(classroom_id,scenario_id,sku,item_name,quantity,reorder_level) values(v_po.classroom_id,null,v_po.sku,v_po.item_name,p_quantity,0)
 on conflict(classroom_id,sku) where scenario_id is null do update set quantity=inventory.quantity+excluded.quantity,updated_at=now() returning quantity into v_stock;
 v_new_received:=v_po.received_quantity+p_quantity;
 update public.purchase_orders set received_quantity=v_new_received,status=case when v_new_received=quantity then 'received' else 'partially_received' end where id=p_purchase_order_id;
 insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata) values(v_po.classroom_id,(select auth.uid()),'purchase_order_received','Received '||p_quantity||' units against '||v_po.po_number,jsonb_build_object('purchase_order_id',p_purchase_order_id,'sku',v_po.sku,'received_now',p_quantity,'received_total',v_new_received,'stock_after',v_stock));
 return jsonb_build_object('received_quantity',v_new_received,'ordered_quantity',v_po.quantity,'stock_quantity',v_stock,'status',case when v_new_received=v_po.quantity then 'received' else 'partially_received' end);
end; $$;

create or replace function public.cancel_purchase_order(p_purchase_order_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_po public.purchase_orders%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_po from public.purchase_orders where id=p_purchase_order_id for update; if not found then raise exception 'Purchase order not found'; end if;
 if not public.is_class_teacher(v_po.classroom_id) then raise exception 'Only the classroom teacher can cancel purchase orders'; end if;
 if v_po.received_quantity>0 then raise exception 'A partially or fully received purchase order cannot be cancelled'; end if;
 update public.purchase_orders set status='cancelled' where id=p_purchase_order_id;
 insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata) values(v_po.classroom_id,(select auth.uid()),'purchase_order_cancelled','Purchase order '||v_po.po_number||' cancelled',jsonb_build_object('purchase_order_id',p_purchase_order_id)); return true;
end; $$;

revoke all on function public.create_supplier(uuid,text,text,integer) from public,anon;
revoke all on function public.create_purchase_order(uuid,uuid,text,text,text,integer,numeric,timestamptz) from public,anon;
revoke all on function public.receive_purchase_order(uuid,integer) from public,anon;
revoke all on function public.cancel_purchase_order(uuid) from public,anon;
grant execute on function public.create_supplier(uuid,text,text,integer) to authenticated;
grant execute on function public.create_purchase_order(uuid,uuid,text,text,text,integer,numeric,timestamptz) to authenticated;
grant execute on function public.receive_purchase_order(uuid,integer) to authenticated;
grant execute on function public.cancel_purchase_order(uuid) to authenticated;
