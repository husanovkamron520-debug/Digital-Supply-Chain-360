
do $migration$
declare v_def text;
begin
 select pg_get_viewdef('public.competition_team_live_metrics'::regclass,true) into v_def;
 v_def:=replace(v_def,
  'COALESCE(o.delivered_units, 0::numeric) AS delivered_units,',
  'CASE WHEN ct.slug = ''amazon-global-combined-crisis'' THEN
    COALESCE((SELECT sum(sh.quantity)::numeric FROM public.competition_shipments sh WHERE sh.team_id=t.id AND sh.status=''delivered''),0::numeric)
    ELSE COALESCE(o.delivered_units, 0::numeric) END AS delivered_units,');
 v_def:=replace(v_def,
  'COALESCE(o.on_time_units, 0::numeric) AS on_time_units,',
  'CASE WHEN ct.slug = ''amazon-global-combined-crisis'' THEN
    COALESCE((SELECT sum(sh.quantity)::numeric FROM public.competition_shipments sh
     JOIN public.competition_customer_orders co ON co.id=sh.order_id
     WHERE sh.team_id=t.id AND sh.status=''delivered'' AND sh.delivered_at<=co.due_at),0::numeric)
    ELSE COALESCE(o.on_time_units, 0::numeric) END AS on_time_units,');
 v_def:=replace(v_def,
  'o.avg_delivery_days,',
  'CASE WHEN ct.slug = ''amazon-global-combined-crisis'' THEN
    (SELECT avg(EXTRACT(epoch FROM sh.delivered_at-sh.dispatched_at)/86400.0)
     FROM public.competition_shipments sh WHERE sh.team_id=t.id AND sh.status=''delivered'')
    ELSE o.avg_delivery_days END AS avg_delivery_days,');
 execute 'create or replace view public.competition_team_live_metrics as '||v_def;
end $migration$;
