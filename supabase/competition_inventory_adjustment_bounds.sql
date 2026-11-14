-- Prevent arbitrary inventory creation through cycle-count adjustments.
-- Limit each correction to 5% of current stock and require an audit reason.
CREATE OR REPLACE FUNCTION public.competition_adjust_inventory(p_team_id uuid, p_sku text, p_delta integer, p_reason text DEFAULT 'Cycle count'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_qty integer; v_current integer; v_max_delta integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['warehouse']) then raise exception 'Only the Warehouse Manager can adjust stock'; end if;
 if p_delta is null or p_delta=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 if char_length(trim(coalesce(p_reason,''))) not between 5 and 300 then raise exception 'Provide a clear cycle-count reason (5-300 characters)'; end if;
 select quantity into v_current from public.competition_inventory
 where team_id=p_team_id and sku=upper(trim(p_sku)) for update;
 if not found then raise exception 'SKU not found'; end if;
 v_max_delta:=greatest(1,floor(v_current*0.05)::integer);
 if abs(p_delta)>v_max_delta then
  raise exception 'Cycle-count adjustment exceeds the 5%% tolerance: maximum allowed change is % units',v_max_delta;
 end if;
 update public.competition_inventory set quantity=quantity+p_delta,updated_at=now()
 where team_id=p_team_id and sku=upper(trim(p_sku)) and quantity+p_delta>=0 returning quantity into v_qty;
 if not found then raise exception 'Adjustment would make stock negative'; end if;
 insert into public.competition_operational_events(competition_id,team_id,classroom_id,actor_id,actor_role,event_type,description,metadata)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,(select auth.uid()),'warehouse','inventory_adjusted','Stock adjusted: '||p_sku,
 jsonb_build_object('delta',p_delta,'quantity_before',v_current,'quantity_after',v_qty,'reason',trim(p_reason),'max_allowed_delta',v_max_delta));
 return v_qty;
end; $function$
;
revoke all on function public.competition_adjust_inventory(uuid,text,integer,text) from public,anon;
grant execute on function public.competition_adjust_inventory(uuid,text,integer,text) to authenticated;
