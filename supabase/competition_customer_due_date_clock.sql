-- Validate due dates against the virtual simulation clock, not wall-clock time.
CREATE OR REPLACE FUNCTION public.competition_create_customer_order(p_team_id uuid, p_order_number text, p_sku text, p_item_name text, p_quantity integer, p_unit_price numeric, p_due_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_team public.competition_teams%rowtype; v_clock public.competition_simulation_clock%rowtype; v_competition_id uuid; v_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select competition_id into v_competition_id from public.competition_teams where id=p_team_id;
 if not found then raise exception 'Team not found'; end if;
 -- Lock the clock first so due-date validation cannot race with a round advance.
 select * into v_clock from public.competition_simulation_clock where competition_id=v_competition_id for update;
 if not found then raise exception 'Simulation clock has not been initialized'; end if;
 select * into v_team from public.competition_teams where id=p_team_id for update;
 if not found then raise exception 'Team not found'; end if;
 if v_team.competition_id<>v_competition_id then raise exception 'Team competition changed; retry the action'; end if;
 if not exists(select 1 from public.competitions where id=v_team.competition_id and status='active') then raise exception 'Competition is not active'; end if;
 if not public.is_competition_role(v_team.competition_id,v_team.id,array['retailer','customer','operations']) then
  raise exception 'Only Customer/Retail Operations can create orders';
 end if;
 if char_length(trim(coalesce(p_order_number,''))) not between 3 and 40 or char_length(trim(coalesce(p_sku,''))) not between 2 and 40 then raise exception 'Invalid order number or SKU'; end if;
 if char_length(trim(coalesce(p_item_name,''))) not between 2 and 120 or p_quantity is null or p_quantity not between 1 and 100000 then raise exception 'Invalid item or quantity'; end if;
 if p_unit_price is null or p_unit_price<=0 or p_unit_price>1000000 then raise exception 'Invalid unit price'; end if;
 if p_due_at is null or p_due_at<=v_clock.virtual_now then
  raise exception 'Due date must be after the current simulation date (%)',v_clock.virtual_now;
 end if;
 insert into public.competition_customer_orders(competition_id,team_id,classroom_id,order_number,sku,item_name,quantity,unit_price,due_at)
 values(v_team.competition_id,v_team.id,v_team.classroom_id,upper(trim(p_order_number)),upper(trim(p_sku)),trim(p_item_name),p_quantity,p_unit_price,p_due_at)
 returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'Order number already exists for this team';
end; $function$
;
revoke all on function public.competition_create_customer_order(uuid,text,text,text,integer,numeric,timestamptz) from public,anon;
grant execute on function public.competition_create_customer_order(uuid,text,text,text,integer,numeric,timestamptz) to authenticated;
