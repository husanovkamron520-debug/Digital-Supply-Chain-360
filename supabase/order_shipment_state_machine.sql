-- SupplyChain14: enforce valid order and shipment lifecycle transitions.
-- Same-state updates are allowed; terminal states cannot be reopened.

create or replace function public.set_supply_order_status(p_order_id uuid,p_status text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_allowed text[];
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if not public.is_class_teacher(v_order.classroom_id) then
    raise exception 'Only the classroom teacher can change order status';
  end if;

  if p_status is null or p_status not in
    ('created','approved','in_production','ready','in_transit','delivered','delayed','cancelled') then
    raise exception 'Invalid order status';
  end if;

  if p_status = v_order.status then
    return p_status;
  end if;

  v_allowed := case v_order.status
    when 'created' then array['approved','delayed','cancelled']
    when 'approved' then array['in_production','delayed','cancelled']
    when 'in_production' then array['ready','delayed']
    when 'ready' then array['in_transit','delayed']
    when 'in_transit' then array['delivered','delayed']
    when 'delayed' then array['approved','in_production','ready','in_transit','cancelled']
    else array[]::text[]
  end;

  if not (p_status = any(v_allowed)) then
    raise exception 'Invalid order transition: % → %', v_order.status, p_status;
  end if;

  update public.orders set status = p_status where id = p_order_id;

  insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
  values(
    v_order.classroom_id,
    (select auth.uid()),
    'order_status_changed',
    'Order ' || v_order.order_number || ': ' || v_order.status || ' → ' || p_status,
    jsonb_build_object('order_id',p_order_id,'from',v_order.status,'to',p_status)
  );

  return p_status;
end;
$$;

create or replace function public.set_supply_shipment_status(p_shipment_id uuid,p_status text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.shipments%rowtype;
  v_role text;
  v_allowed text[];
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required';
  end if;

  select * into v_shipment
  from public.shipments
  where id = p_shipment_id
  for update;

  if not found then
    raise exception 'Shipment not found';
  end if;

  if not public.is_class_teacher(v_shipment.classroom_id) then
    select m.operational_role into v_role
    from public.classroom_members m
    where m.classroom_id = v_shipment.classroom_id
      and m.student_id = (select auth.uid());

    if v_role is distinct from 'transport' then
      raise exception 'Only the teacher or assigned Transport Manager can update shipments';
    end if;
  end if;

  if p_status is null or p_status not in ('planned','dispatched','in_transit','delayed','delivered') then
    raise exception 'Invalid shipment status';
  end if;

  if p_status = v_shipment.status then
    return p_status;
  end if;

  v_allowed := case v_shipment.status
    when 'planned' then array['dispatched','delayed']
    when 'dispatched' then array['in_transit','delayed']
    when 'in_transit' then array['delivered','delayed']
    when 'delayed' then array['planned','dispatched','in_transit']
    else array[]::text[]
  end;

  if not (p_status = any(v_allowed)) then
    raise exception 'Invalid shipment transition: % → %', v_shipment.status, p_status;
  end if;

  update public.shipments set status = p_status where id = p_shipment_id;

  insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
  values(
    v_shipment.classroom_id,
    (select auth.uid()),
    'shipment_status_changed',
    'Shipment ' || left(p_shipment_id::text,8) || ': ' || v_shipment.status || ' → ' || p_status,
    jsonb_build_object('shipment_id',p_shipment_id,'from',v_shipment.status,'to',p_status)
  );

  return p_status;
end;
$$;

revoke all on function public.set_supply_order_status(uuid,text) from public, anon;
revoke all on function public.set_supply_shipment_status(uuid,text) from public, anon;
grant execute on function public.set_supply_order_status(uuid,text) to authenticated;
grant execute on function public.set_supply_shipment_status(uuid,text) to authenticated;
