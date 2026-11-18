
create or replace function public.amazon_validate_procurement_mix(p_competition_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v record; v_total integer; v_a integer; v_bc integer; v_share numeric;
begin
 for v in select s.team_id,s.strategic_posture from public.amazon_case_team_state s where s.competition_id=p_competition_id loop
  select coalesce(sum(po.quantity),0),
   coalesce(sum(po.quantity) filter(where o.supplier_code='SUP-A'),0),
   coalesce(sum(po.quantity) filter(where o.supplier_code in ('SUP-B','SUP-C')),0)
  into v_total,v_a,v_bc
  from public.competition_purchase_orders po
  join public.amazon_case_supplier_offers o on o.team_id=po.team_id and o.supplier_id=po.supplier_id and o.sku=po.sku
  where po.team_id=v.team_id and po.status<>'cancelled';
  if v_total=0 then raise exception 'Team % must submit a procurement plan before closing the round',v.team_id; end if;
  v_share:=v_a::numeric/v_total;
  if v.strategic_posture='cost_focused' and v_share<0.60 then
   raise exception 'Cost-focused procurement limit failed: at least 60%% of ordered units must come from Supplier A';
  elsif v.strategic_posture='balanced' and v_share not between 0.40 and 0.70 then
   raise exception 'Balanced procurement limit failed: Supplier A share must be 40%%–70%%';
  elsif v.strategic_posture='service_focused' and v_bc::numeric/v_total<0.60 then
   raise exception 'Service-focused procurement limit failed: at least 60%% must come from Suppliers B+C';
  end if;
 end loop;
end; $$;
grant execute on function public.amazon_validate_procurement_mix(uuid) to authenticated;

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_initialize_team(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' delete from public.competition_inventory where team_id=p_team_id;',
  ' delete from public.competition_ledger where team_id=p_team_id and entry_type=''capital'';
  delete from public.competition_inventory where team_id=p_team_id;');
 execute v_def;
 select pg_get_functiondef('public.amazon_advance_round(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if v_clock.current_round>=3 then raise exception ''Final round reached''; end if;',
  ' if v_clock.current_round>=3 then raise exception ''Final round reached''; end if;
  perform public.amazon_validate_procurement_mix(p_competition_id);');
 execute v_def;
end $migration$;
