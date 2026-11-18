
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.competition_create_purchase_order(uuid,uuid,text,text,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Team not found''; end if;',
  ' if not found then raise exception ''Team not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Use the Amazon procurement order workflow for this case''; end if;');
 execute v_def;

 select pg_get_functiondef('public.competition_receive_purchase_order(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Purchase order not found''; end if;
 select * into v_clock',
  ' if not found then raise exception ''Purchase order not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Use the Amazon warehouse receiving workflow for this case''; end if;
 select * into v_clock');
 execute v_def;

 select pg_get_functiondef('public.competition_complete_production(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Team not found''; end if;
 -- Lock the simulation clock',
  ' if not found then raise exception ''Team not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Amazon case has no manufacturing step; use Fulfillment Operations''; end if;
 -- Lock the simulation clock');
 execute v_def;

 select pg_get_functiondef('public.competition_create_customer_order(uuid,text,text,text,integer,numeric,timestamptz)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Team not found''; end if;
 select * into v_clock',
  ' if not found then raise exception ''Team not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Amazon case demand is pre-seeded; manual customer orders are disabled''; end if;
 select * into v_clock');
 execute v_def;

 select pg_get_functiondef('public.competition_dispatch_shipment(uuid,integer,text,text,text,numeric)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Customer order not found''; end if;
 select * into v_clock',
  ' if not found then raise exception ''Customer order not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Use Amazon pick-pack release and service-level dispatch workflow''; end if;
 select * into v_clock');
 execute v_def;

 select pg_get_functiondef('public.competition_update_supplier_terms(uuid,integer,numeric,numeric)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not found then raise exception ''Supplier not found''; end if;
 select * into v_clock',
  ' if not found then raise exception ''Supplier not found''; end if;
 if exists(select 1 from public.competitions c where c.id=v_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Amazon supplier offers are fixed; record commitments through Supplier Relations''; end if;
 select * into v_clock');
 execute v_def;

 select pg_get_functiondef('public.competition_advance_round(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not public.is_class_teacher(v_classroom_id) then raise exception ''Only the teacher can advance the simulation''; end if;',
  ' if not public.is_class_teacher(v_classroom_id) then raise exception ''Only the teacher can advance the simulation''; end if;
 if exists(select 1 from public.competitions c where c.id=p_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''Use the Amazon 10-day round controller''; end if;');
 execute v_def;
end $migration$;
