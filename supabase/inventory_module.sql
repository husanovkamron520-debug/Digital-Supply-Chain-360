-- Digital Supply Chain 360: Warehouse inventory module
-- Run once in Supabase SQL Editor after the base schema.

create unique index if not exists inventory_classroom_sku_base_uidx
  on public.inventory (classroom_id, sku)
  where scenario_id is null;

create or replace function public.create_inventory_item(
  p_classroom_id uuid,
  p_sku text,
  p_item_name text,
  p_quantity integer default 0,
  p_reorder_level integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_sku text := upper(trim(coalesce(p_sku, '')));
  v_name text := trim(coalesce(p_item_name, ''));
begin
  if auth.uid() is null then
    raise exception 'You must sign in first';
  end if;

  if not (
    public.is_class_teacher(p_classroom_id)
    or exists (
      select 1 from public.classroom_members m
      where m.classroom_id = p_classroom_id
        and m.student_id = auth.uid()
        and m.operational_role = 'warehouse'
    )
  ) then
    raise exception 'Only the teacher or assigned Warehouse Manager can manage inventory';
  end if;

  if char_length(v_sku) not between 2 and 40 then
    raise exception 'SKU must be 2-40 characters';
  end if;
  if char_length(v_name) not between 2 and 120 then
    raise exception 'Product name must be 2-120 characters';
  end if;
  if p_quantity is null or p_quantity < 0 then
    raise exception 'Opening quantity cannot be negative';
  end if;
  if p_reorder_level is null or p_reorder_level < 0 then
    raise exception 'Reorder level cannot be negative';
  end if;

  insert into public.inventory (classroom_id, scenario_id, sku, item_name, quantity, reorder_level)
  values (p_classroom_id, null, v_sku, v_name, p_quantity, p_reorder_level)
  returning id into v_id;

  insert into public.activity_logs (classroom_id, actor_id, event_type, description, metadata)
  values (
    p_classroom_id,
    auth.uid(),
    'inventory_item_created',
    'Inventory item created: ' || v_sku,
    jsonb_build_object('inventory_id', v_id, 'sku', v_sku, 'item_name', v_name, 'quantity', p_quantity)
  );

  return v_id;
exception
  when unique_violation then
    raise exception 'This SKU already exists in this classroom';
end;
$$;

create or replace function public.adjust_inventory_quantity(
  p_inventory_id uuid,
  p_delta integer,
  p_reason text default 'Manual stock adjustment'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.inventory%rowtype;
  v_new_quantity integer;
  v_event text;
begin
  if auth.uid() is null then
    raise exception 'You must sign in first';
  end if;
  if p_delta is null or p_delta = 0 then
    raise exception 'Quantity change must not be zero';
  end if;

  select * into v_item
  from public.inventory
  where id = p_inventory_id and scenario_id is null
  for update;

  if not found then
    raise exception 'Inventory item not found';
  end if;

  if not (
    public.is_class_teacher(v_item.classroom_id)
    or exists (
      select 1 from public.classroom_members m
      where m.classroom_id = v_item.classroom_id
        and m.student_id = auth.uid()
        and m.operational_role = 'warehouse'
    )
  ) then
    raise exception 'Only the teacher or assigned Warehouse Manager can manage inventory';
  end if;

  v_new_quantity := v_item.quantity + p_delta;
  if v_new_quantity < 0 then
    raise exception 'Insufficient stock: only % units are available', v_item.quantity;
  end if;

  update public.inventory
  set quantity = v_new_quantity, updated_at = now()
  where id = p_inventory_id;

  v_event := case when p_delta > 0 then 'inventory_received' else 'inventory_issued' end;
  insert into public.activity_logs (classroom_id, actor_id, event_type, description, metadata)
  values (
    v_item.classroom_id,
    auth.uid(),
    v_event,
    case when p_delta > 0
      then 'Received ' || p_delta || ' units of ' || v_item.sku
      else 'Issued ' || abs(p_delta) || ' units of ' || v_item.sku
    end,
    jsonb_build_object(
      'inventory_id', p_inventory_id,
      'sku', v_item.sku,
      'delta', p_delta,
      'quantity_before', v_item.quantity,
      'quantity_after', v_new_quantity,
      'reason', coalesce(nullif(trim(p_reason), ''), 'Manual stock adjustment')
    )
  );

  return v_new_quantity;
end;
$$;

-- Inventory is read through RLS; all stock mutations go through the validated RPCs.
revoke insert, update, delete on public.inventory from anon, authenticated;
grant select on public.inventory to authenticated;

revoke all on function public.create_inventory_item(uuid, text, text, integer, integer) from public;
revoke all on function public.adjust_inventory_quantity(uuid, integer, text) from public;
grant execute on function public.create_inventory_item(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.adjust_inventory_quantity(uuid, integer, text) to authenticated;
