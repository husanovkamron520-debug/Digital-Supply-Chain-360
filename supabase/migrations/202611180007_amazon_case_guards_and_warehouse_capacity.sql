
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,' v_new integer; v_stock integer; v_cost numeric; v_competition_id uuid;',
  ' v_new integer; v_stock integer; v_cost numeric; v_competition_id uuid; v_capacity integer; v_occupied integer;');
 v_def:=replace(v_def,
  ' if not found then raise exception ''Purchase order not found''; end if;
 if not public.is_competition_role',
  ' if not found then raise exception ''Purchase order not found''; end if;
 if not exists(select 1 from public.competitions c where c.id=v_po.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case purchase order''; end if;
 if not public.is_competition_role');
 v_def:=replace(v_def,
  ' v_cost:=p_quantity*v_po.unit_cost;',
  ' select warehouse_capacity_units into v_capacity from public.amazon_case_team_state where team_id=v_po.team_id;
 select coalesce(sum(quantity),0) into v_occupied from public.competition_inventory where team_id=v_po.team_id;
 if v_occupied+p_quantity>v_capacity then raise exception ''Warehouse capacity exceeded: available headroom is % units'',greatest(0,v_capacity-v_occupied); end if;
 v_cost:=p_quantity*v_po.unit_cost;');
 execute v_def;

 select pg_get_functiondef('public.amazon_fulfill_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' select status into v_comp_status from public.competitions where id=v_order.competition_id;
 if v_comp_status<>''active''',
  ' select status into v_comp_status from public.competitions where id=v_order.competition_id;
 if not exists(select 1 from public.competitions c where c.id=v_order.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case order''; end if;
 if v_comp_status<>''active''');
 execute v_def;

 select pg_get_functiondef('public.amazon_dispatch_shipment(uuid,integer,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Customer order not found''; end if;
 if not public.is_competition_role',
  ' if not found then raise exception ''Customer order not found''; end if;
 if not exists(select 1 from public.competitions c where c.id=v_order.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case order''; end if;
 if not public.is_competition_role');
 execute v_def;

 select pg_get_functiondef('public.amazon_submit_approval(uuid,text,text,jsonb)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Team not found''; end if;
 if p_approval_type',
  ' if not found then raise exception ''Team not found''; end if;
 if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case team''; end if;
 if p_approval_type');
 execute v_def;

 select pg_get_functiondef('public.amazon_advance_round(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not public.is_class_teacher(v_classroom) then raise exception ''Only teacher can advance rounds''; end if;',
  ' if not public.is_class_teacher(v_classroom) then raise exception ''Only teacher can advance rounds''; end if;
 if not exists(select 1 from public.competitions c where c.id=p_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case''; end if;');
 execute v_def;
end $migration$;

create or replace function public.amazon_set_posture(p_team_id uuid,p_posture text)
returns text language plpgsql security definer set search_path=''
as $$
begin
 raise exception 'Procurement strategy changes require a team approval request';
end; $$;
