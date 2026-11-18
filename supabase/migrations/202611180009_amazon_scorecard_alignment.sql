
update public.company_templates
set operating_profile=operating_profile || '{"target_cost_per_unit":20}'::jsonb
where slug='amazon-global-combined-crisis';

do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_initialize_team(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'values(v_team.competition_id,p_team_id,v_team.classroom_id,v_sku.sku,v_sku.item_name,''finished_goods'',v_sku.opening_stock,0,0);',
  'values(v_team.competition_id,p_team_id,v_team.classroom_id,v_sku.sku,v_sku.item_name,''finished_goods'',v_sku.opening_stock,
   case v_sku.sku when ''SKU-01'' then 280 when ''SKU-02'' then 350 when ''SKU-03'' then 168 when ''SKU-04'' then 112 else 70 end,0);');
 execute v_def;

 select pg_get_viewdef('public.competition_team_live_metrics'::regclass,true) into v_def;
 v_def:=replace(v_def,'ct.name AS company_name,
            ct.scoring_weights,','ct.name AS company_name,
            ct.slug AS template_slug,
            ct.scoring_weights,');
 v_def:=replace(v_def,
  'CASE
                    WHEN r.ordered_units > 0::numeric THEN
                    CASE
                        WHEN GREATEST(r.ordered_units - r.initial_finished_units, 0::numeric) = 0::numeric THEN
                        CASE
                            WHEN r.produced_units = 0::numeric THEN 100::numeric
                            ELSE 0::numeric
                        END
                        ELSE GREATEST(0::numeric, round(100::numeric - abs(r.produced_units - GREATEST(r.ordered_units - r.initial_finished_units, 0::numeric)) * 100::numeric / GREATEST(r.ordered_units - r.initial_finished_units, 1::numeric), 2))
                    END
                    ELSE NULL::numeric
                END AS productivity_score',
  'CASE
                    WHEN r.template_slug = ''amazon-global-combined-crisis'' THEN
                     CASE WHEN r.ordered_units > 0::numeric THEN LEAST(100::numeric,round(100::numeric *
                      ((SELECT COALESCE(sum(sh.quantity),0) FROM public.competition_shipments sh WHERE sh.team_id=r.team_id AND sh.status<>''cancelled'')
                       +(SELECT COALESCE(sum(f.ready_quantity),0) FROM public.amazon_case_fulfillment f WHERE f.team_id=r.team_id))
                      / r.ordered_units,2)) ELSE NULL::numeric END
                    WHEN r.ordered_units > 0::numeric THEN
                    CASE
                        WHEN GREATEST(r.ordered_units - r.initial_finished_units, 0::numeric) = 0::numeric THEN
                        CASE
                            WHEN r.produced_units = 0::numeric THEN 100::numeric
                            ELSE 0::numeric
                        END
                        ELSE GREATEST(0::numeric, round(100::numeric - abs(r.produced_units - GREATEST(r.ordered_units - r.initial_finished_units, 0::numeric)) * 100::numeric / GREATEST(r.ordered_units - r.initial_finished_units, 1::numeric), 2))
                    END
                    ELSE NULL::numeric
                END AS productivity_score');
 execute 'create or replace view public.competition_team_live_metrics as '||v_def;
end $migration$;
