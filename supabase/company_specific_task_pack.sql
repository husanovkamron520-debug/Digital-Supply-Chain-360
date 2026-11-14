-- Company-specific task packs grounded in public supply-chain descriptions.
-- All operating values remain synthetic educational parameters.
CREATE OR REPLACE FUNCTION public.create_competition_standard_task_pack(p_competition_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_classroom_id uuid; v_status text; v_team record; v_count integer:=0;
 v_proc_title text; v_proc_desc text; v_supplier_title text; v_supplier_desc text;
 v_mfg_title text; v_mfg_desc text; v_wh_title text; v_wh_desc text; v_transport_title text; v_transport_desc text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the teacher can create standard team tasks'; end if;
 if v_status not in('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then
  raise exception 'Tasks already exist. Add custom tasks instead of duplicating the standard pack';
 end if;
 for v_team in
  select t.id,t.name,ct.name as company_name,ct.slug
  from public.competition_teams t join public.company_templates ct on ct.id=t.company_template_id
  where t.competition_id=p_competition_id
 loop
  if not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='procurement')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='supplier')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='manufacturer')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='warehouse')
   or not exists(select 1 from public.competition_team_members where competition_id=p_competition_id and team_id=v_team.id and operational_role='transport') then
   raise exception 'Each team must have Procurement, Supplier, Manufacturer, Warehouse and Transport roles before generating the task pack';
  end if;

  v_proc_title:=case v_team.slug
   when 'lean-automotive' then 'Protect just-in-time supply continuity'
   when 'omnichannel-retail' then 'Position inventory for forecasted demand'
   when 'flatpack-global' then 'Source sustainable flat-pack materials'
   when 'beverage-fast-moving' then 'Secure ingredients and packaging for bottling'
   else 'Source critical raw materials' end;
  v_proc_desc:=case v_team.slug
   when 'lean-automotive' then 'Compare supplier offers by cost, lead time and quality reliability. Select a source that supports Just-in-Time replenishment without creating excess stock. Place an RM-001 purchase order and explain the service-versus-inventory trade-off.'
   when 'omnichannel-retail' then 'Estimate demand by customer region and choose a supplier/replenishment plan that positions merchant inventory close to likely orders. Place an RM-001 purchase order and explain the speed, cost and stock-placement trade-off.'
   when 'flatpack-global' then 'Compare global suppliers by total landed cost, lead time, material quality and responsible sourcing. Select components that support flat-pack design and efficient container utilisation. Place an RM-001 purchase order.'
   when 'beverage-fast-moving' then 'Secure ingredients and packaging with dependable quality, lead time and supply continuity. Compare supplier offers and place an RM-001 purchase order while considering shelf-life and production schedule risk.'
   else 'Compare suppliers by unit cost, lead time and reliability. Select the best total-value option and place an RM-001 purchase order.' end;

  v_supplier_title:=case v_team.slug
   when 'lean-automotive' then 'Improve supplier reliability for JIT'
   when 'omnichannel-retail' then 'Negotiate replenishment and fulfilment service'
   when 'flatpack-global' then 'Align global supplier cost and sustainability'
   when 'beverage-fast-moving' then 'Assure ingredient and packaging quality'
   else 'Negotiate supplier performance' end;
  v_supplier_desc:=case v_team.slug
   when 'lean-automotive' then 'Negotiate delivery-window discipline, quality and lead time with a supplier. Explain how Jidoka-quality response and reliable replenishment reduce line-stop risk; do not optimise unit price alone.'
   when 'omnichannel-retail' then 'Negotiate supplier lead time, unit cost and reliability to support frequent replenishment and fulfilment availability. Explain how the terms affect stock positioning and customer promise speed.'
   when 'flatpack-global' then 'Negotiate total landed cost, component quality, responsible sourcing and dependable long-distance delivery. Explain how supplier choices affect flat-pack cost and transport efficiency.'
   when 'beverage-fast-moving' then 'Negotiate reliable ingredient and packaging supply, quality consistency and delivery windows. Explain how shortages or quality failures disrupt bottling schedules and local availability.'
   else 'Review the supplier portfolio and negotiate lead time, unit cost and reliability. Explain the trade-off between price, risk and continuity.' end;

  v_mfg_title:=case v_team.slug
   when 'lean-automotive' then 'Synchronise lean production and quality'
   when 'omnichannel-retail' then 'Prepare seller inventory for fulfilment'
   when 'flatpack-global' then 'Produce and pack flat-pack products'
   when 'beverage-fast-moving' then 'Schedule high-volume bottling'
   else 'Plan and execute production' end;
  v_mfg_desc:=case v_team.slug
   when 'lean-automotive' then 'Plan output against downstream demand and available components. Run production only when required, protect line balance and stop/escalate when a quality abnormality is identified. Explain how you avoided overproduction.'
   when 'omnichannel-retail' then 'This role represents the seller or upstream production partner, not Amazon manufacturing. Prepare the right quantity of merchant inventory for fulfilment based on demand and available stock; avoid excess inventory and explain the hand-off to the fulfilment network.'
   when 'flatpack-global' then 'Plan production of furniture components and finished flat-pack products. Consider packaging density, component availability and production capacity so products can be consolidated and transported efficiently.'
   when 'beverage-fast-moving' then 'Plan a bottling run using available ingredients and packaging. Match output to demand, production capacity and shelf-life; explain how you prevent both shortages and unnecessary finished-goods stock.'
   else 'Use available raw-material stock and production capacity to plan output for open customer orders. Explain how you avoided shortages and excess production.' end;

  v_wh_title:=case v_team.slug
   when 'lean-automotive' then 'Maintain Kanban and low safety stock'
   when 'omnichannel-retail' then 'Position inventory across fulfilment nodes'
   when 'flatpack-global' then 'Consolidate stock and storage efficiently'
   when 'beverage-fast-moving' then 'Control FIFO stock and shelf-life'
   else 'Control receipts and inventory' end;
  v_wh_desc:=case v_team.slug
   when 'lean-automotive' then 'Receive only when supplier availability is reached. Monitor RM-001 and FG-001 against reorder points and use a Kanban-style replenishment mindset: enough material to protect flow, not excess stock.'
   when 'omnichannel-retail' then 'Receive merchant inventory accurately and decide how much stock should be available for fast fulfilment. Monitor stockouts and excess inventory while considering that placement near customers improves speed but raises network complexity.'
   when 'flatpack-global' then 'Receive components and finished flat-pack products accurately. Consolidate stock, protect storage capacity and monitor reorder levels to avoid expensive excess inventory across a global network.'
   when 'beverage-fast-moving' then 'Receive ingredients, packaging and finished beverages accurately. Apply FIFO stock rotation, monitor reorder levels and avoid holding excess products that could become obsolete or pass shelf-life limits.'
   else 'Check purchase-order availability before receipt, record stock accurately and balance service against inventory carrying cost.' end;

  v_transport_title:=case v_team.slug
   when 'lean-automotive' then 'Synchronise line-side and outbound transport'
   when 'omnichannel-retail' then 'Optimise fulfilment and last-mile delivery'
   when 'flatpack-global' then 'Maximise container utilisation'
   when 'beverage-fast-moving' then 'Coordinate regional beverage distribution'
   else 'Fulfil customer deliveries' end;
  v_transport_desc:=case v_team.slug
   when 'lean-automotive' then 'Prioritise customer orders and coordinate inbound/outbound movements so components and finished vehicles arrive on time. Choose a cost-effective carrier without risking production or delivery reliability.'
   when 'omnichannel-retail' then 'Dispatch available inventory through a suitable fulfilment route and carrier. Balance delivery speed, transport cost and last-mile reliability; confirm delivery only after the simulated ETA.'
   when 'flatpack-global' then 'Choose routes and carriers that protect flat-pack products and maximise container/cube utilisation. Balance long-distance lead time, freight cost and customer delivery commitments.'
   when 'beverage-fast-moving' then 'Prioritise regional customer orders and select efficient routes for high-volume beverage distribution. Balance delivery reliability, transport cost and stock freshness.'
   else 'Prioritise open customer orders, dispatch available finished goods, choose a suitable carrier and route, then confirm delivery when the simulated ETA is reached.' end;

  insert into public.competition_tasks(competition_id,team_id,classroom_id,assigned_role,title,description,priority,due_at,due_round,created_by)
  values
   (p_competition_id,v_team.id,v_classroom_id,'procurement',v_proc_title,v_proc_desc,'high',null,1,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'supplier',v_supplier_title,v_supplier_desc,'high',null,1,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'manufacturer',v_mfg_title,v_mfg_desc,'high',null,2,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'warehouse',v_wh_title,v_wh_desc,'normal',null,2,(select auth.uid())),
   (p_competition_id,v_team.id,v_classroom_id,'transport',v_transport_title,v_transport_desc,'high',null,3,(select auth.uid()));
  v_count:=v_count+5;
 end loop;
 return v_count;
end; $function$
;
revoke all on function public.create_competition_standard_task_pack(uuid) from public,anon;
grant execute on function public.create_competition_standard_task_pack(uuid) to authenticated;
