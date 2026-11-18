
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.create_balanced_competition_teams(uuid,integer)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'where slug=''omnichannel-retail'' and active;',
  'where slug=case when exists(select 1 from public.competitions c where c.id=p_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then ''amazon-global-combined-crisis'' else ''omnichannel-retail'' end and active;');
 v_def:=replace(v_def,
  ' return jsonb_build_object(',
  ' if exists(select 1 from public.competitions c where c.id=p_competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then
   foreach v_team_id in array v_team_ids loop perform public.amazon_initialize_team(v_team_id); end loop;
  end if;
  return jsonb_build_object(');
 execute v_def;
end $migration$;

create or replace function public.amazon_get_case_data(p_team_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_team public.competition_teams%rowtype; v_state public.amazon_case_team_state%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competition_team_members where team_id=p_team_id and student_id=(select auth.uid()))
    and not public.is_class_teacher(v_team.classroom_id) then raise exception 'You are not a member of this team'; end if;
 select * into v_state from public.amazon_case_team_state where team_id=p_team_id;
 if not found then raise exception 'Amazon case team is not initialized'; end if;
 return jsonb_build_object(
  'state',to_jsonb(v_state),
  'skus',(select jsonb_agg(to_jsonb(s) order by s.sku) from public.amazon_case_skus s),
  'offers',(select jsonb_agg(jsonb_build_object('supplier_code',o.supplier_code,'supplier_name',cs.name,'sku',o.sku,'unit_price',o.unit_price,'moq',o.moq,'max_capacity',o.max_capacity,'lead_time_days',o.lead_time_days) order by o.sku,o.supplier_code)
   from public.amazon_case_supplier_offers o join public.competition_suppliers cs on cs.id=o.supplier_id where o.team_id=p_team_id),
  'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb) from public.amazon_case_approvals a where a.team_id=p_team_id and a.status='pending')
 );
end; $$;
grant execute on function public.amazon_get_case_data(uuid) to authenticated;
