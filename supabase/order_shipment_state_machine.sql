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


-- Keep operational shipment creation isolated from scenario-tagged orders.

create or replace function public.create_supply_shipment(p_classroom_id uuid,p_order_id uuid,p_origin text,p_destination text,p_carrier text default 'Demo carrier',p_eta timestamptz default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_role text; v_origin text:=trim(coalesce(p_origin,'')); v_destination text:=trim(coalesce(p_destination,'')); v_carrier text:=trim(coalesce(p_carrier,'Demo carrier'));
begin
  if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
  if not public.is_class_teacher(p_classroom_id) then
    select m.operational_role into v_role from public.classroom_members m where m.classroom_id=p_classroom_id and m.student_id=(select auth.uid());
    if v_role is distinct from 'transport' then raise exception 'Only the teacher or assigned Transport Manager can create shipments'; end if;
  end if;
  if char_length(v_origin) not between 2 and 120 or char_length(v_destination) not between 2 and 120 then raise exception 'Origin and destination must be 2-120 characters'; end if;
  if char_length(v_carrier) not between 2 and 80 then raise exception 'Carrier must be 2-80 characters'; end if;
  if p_eta is not null and p_eta<now()-interval '1 day' then raise exception 'ETA is too far in the past'; end if;
  if p_order_id is not null and not exists(select 1 from public.orders o where o.id=p_order_id and o.classroom_id=p_classroom_id and o.scenario_id is null) then raise exception 'Selected operational order does not belong to this classroom'; end if;
  insert into public.shipments(classroom_id,order_id,created_by,origin,destination,carrier,eta)
  values(p_classroom_id,p_order_id,(select auth.uid()),v_origin,v_destination,v_carrier,p_eta) returning id into v_id;
  insert into public.activity_logs(classroom_id,actor_id,event_type,description,metadata)
  values(p_classroom_id,(select auth.uid()),'shipment_created','Shipment created: '||v_origin||' → '||v_destination,
    jsonb_build_object('shipment_id',v_id,'order_id',p_order_id,'carrier',v_carrier));
  return v_id;
end; $$;
revoke all on function public.create_supply_shipment(uuid,uuid,text,text,text,timestamptz) from public,anon;
grant execute on function public.create_supply_shipment(uuid,uuid,text,text,text,timestamptz) to authenticated;
