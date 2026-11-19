create or replace function public.amazon_record_putaway(
  p_quality_receipt_id uuid,
  p_quantity integer,
  p_location_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_receipt public.amazon_case_quality_receipts%rowtype;
  v_classroom_id uuid;
  v_already integer;
  v_remaining integer;
  v_round integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in is required';
  end if;

  if p_quantity is null or p_quantity < 1 then
    raise exception 'Put-away quantity must be positive';
  end if;

  if p_location_code is null
     or length(trim(p_location_code)) < 2
     or length(trim(p_location_code)) > 32
     or trim(p_location_code) !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Enter a valid warehouse location code (2-32 letters, numbers, - or _)';
  end if;

  select *
    into v_receipt
    from public.amazon_case_quality_receipts
   where id = p_quality_receipt_id
   for update;

  if not found then
    raise exception 'Quality receipt not found';
  end if;

  if not exists (
    select 1
      from public.competitions c
     where c.id = v_receipt.competition_id
       and c.settings->>'case_code' = 'amazon-global-combined-crisis'
       and c.status = 'active'
  ) then
    raise exception 'Amazon case is not active';
  end if;

  if not public.is_competition_role(
    v_receipt.competition_id,
    v_receipt.team_id,
    array['warehouse']
  ) then
    raise exception 'Only Warehouse Manager can complete put-away';
  end if;

  perform private.amazon_assert_round_open(v_receipt.competition_id);

  select classroom_id
    into v_classroom_id
    from public.competition_teams
   where id = v_receipt.team_id;

  select coalesce(sum((metadata->>'quantity')::integer), 0)
    into v_already
    from public.competition_operational_events
   where team_id = v_receipt.team_id
     and event_type = 'amazon_warehouse_putaway'
     and metadata->>'quality_receipt_id' = p_quality_receipt_id::text;

  v_remaining := greatest(0, v_receipt.usable_quantity - v_already);
  if p_quantity > v_remaining then
    raise exception 'Put-away exceeds unlocated usable stock; remaining quantity is %', v_remaining;
  end if;

  select current_round
    into v_round
    from public.competition_simulation_clock
   where competition_id = v_receipt.competition_id;

  insert into public.competition_operational_events(
    competition_id, team_id, classroom_id, actor_id, actor_role,
    event_type, description, metadata
  )
  values (
    v_receipt.competition_id,
    v_receipt.team_id,
    v_classroom_id,
    (select auth.uid()),
    'warehouse',
    'amazon_warehouse_putaway',
    'Usable received stock assigned to a warehouse storage location',
    jsonb_build_object(
      'quality_receipt_id', p_quality_receipt_id,
      'purchase_order_id', v_receipt.purchase_order_id,
      'sku', v_receipt.sku,
      'quantity', p_quantity,
      'location_code', upper(trim(p_location_code)),
      'round', v_round
    )
  );

  return jsonb_build_object(
    'quality_receipt_id', p_quality_receipt_id,
    'sku', v_receipt.sku,
    'putaway_quantity', p_quantity,
    'putaway_total', v_already + p_quantity,
    'remaining_to_putaway', v_remaining - p_quantity,
    'location_code', upper(trim(p_location_code))
  );
end;
$function$;

revoke all on function public.amazon_record_putaway(uuid, integer, text) from public;
revoke all on function public.amazon_record_putaway(uuid, integer, text) from anon;
grant execute on function public.amazon_record_putaway(uuid, integer, text) to authenticated;
