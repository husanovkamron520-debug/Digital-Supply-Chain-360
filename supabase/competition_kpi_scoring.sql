-- Transparent normalized KPI scorecard: OTIF, cost per delivered unit, inventory balance,
-- company-relative lead time, production-plan attainment and teacher-evaluated decisions.
create or replace view public.competition_team_live_metrics with (security_invoker=true) as
 WITH order_metrics AS (
         SELECT competition_customer_orders.team_id,
            count(*) FILTER (WHERE competition_customer_orders.status <> 'cancelled'::text)::integer AS total_orders,
            count(*) FILTER (WHERE competition_customer_orders.status = 'delivered'::text)::integer AS delivered_orders,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text), 0::bigint)::numeric AS delivered_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status <> 'cancelled'::text), 0::bigint)::numeric AS ordered_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status <> 'cancelled'::text AND (competition_customer_orders.status = 'delivered'::text OR competition_customer_orders.due_at <= clk.virtual_now)), 0::bigint)::numeric AS due_units,
            COALESCE(sum(competition_customer_orders.quantity) FILTER (WHERE competition_customer_orders.status = 'delivered'::text AND competition_customer_orders.delivered_at <= competition_customer_orders.due_at), 0::bigint)::numeric AS on_time_units,
            avg(EXTRACT(epoch FROM competition_customer_orders.delivered_at - competition_customer_orders.created_at) / 86400.0) FILTER (WHERE competition_customer_orders.status = 'delivered'::text) AS avg_delivery_days
           FROM competition_customer_orders
             JOIN competition_simulation_clock clk ON clk.competition_id = competition_customer_orders.competition_id
          GROUP BY competition_customer_orders.team_id
        ), inventory_metrics AS (
         SELECT competition_inventory.team_id,
            count(*)::integer AS sku_count,
            count(*) FILTER (WHERE competition_inventory.quantity > competition_inventory.reorder_level)::integer AS healthy_skus,
            COALESCE(sum(competition_inventory.quantity), 0::bigint)::numeric AS inventory_units,
            COALESCE(sum(competition_inventory.quantity::numeric * competition_inventory.unit_cost), 0::numeric) AS inventory_value,
            count(*) FILTER (WHERE competition_inventory.quantity <= competition_inventory.reorder_level)::integer AS low_stock_skus,
            round(avg(
                CASE
                    WHEN competition_inventory.reorder_level <= 0 THEN 100::numeric
                    WHEN competition_inventory.quantity < competition_inventory.reorder_level THEN GREATEST(0::numeric, 100::numeric * competition_inventory.quantity::numeric / competition_inventory.reorder_level::numeric)
                    WHEN competition_inventory.quantity::numeric <= (competition_inventory.reorder_level::numeric * 2.5) THEN 100::numeric
                    ELSE GREATEST(0::numeric, 100::numeric - 50::numeric * (competition_inventory.quantity::numeric / (competition_inventory.reorder_level::numeric * 2.5) - 1::numeric))
                END), 2) AS inventory_health_score
           FROM competition_inventory
          GROUP BY competition_inventory.team_id
        ), production_metrics AS (
         SELECT competition_production_runs.team_id,
            COALESCE(sum(competition_production_runs.produced_quantity), 0::bigint)::numeric AS produced_units,
            count(*)::integer AS production_runs
           FROM competition_production_runs
          WHERE competition_production_runs.status = 'completed'::text
          GROUP BY competition_production_runs.team_id
        ), finance_metrics AS (
         SELECT competition_ledger.team_id,
            COALESCE(sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = 'revenue'::text), 0::numeric) AS revenue,
            COALESCE(- sum(competition_ledger.amount) FILTER (WHERE competition_ledger.entry_type = ANY (ARRAY['purchase'::text, 'production'::text, 'transport'::text, 'adjustment'::text])), 0::numeric) AS operating_cost
           FROM competition_ledger
          GROUP BY competition_ledger.team_id
        ), decision_metrics AS (
         SELECT competition_decisions.team_id,
            avg(competition_decisions.score) AS decision_quality,
            count(*)::integer AS decision_count,
            count(*) FILTER (WHERE competition_decisions.score IS NOT NULL)::integer AS evaluated_decisions
           FROM competition_decisions
          GROUP BY competition_decisions.team_id
        ), raw AS (
         SELECT t.id AS team_id,
            t.competition_id,
            t.classroom_id,
            t.name AS team_name,
            t.starting_capital,
            t.cash_balance,
            COALESCE(clk.current_round, 1) AS current_round,
            t.production_capacity_units,
            ct.name AS company_name,
            ct.scoring_weights,
            COALESCE(o.total_orders, 0) AS total_orders,
            COALESCE(o.delivered_orders, 0) AS delivered_orders,
            COALESCE(o.delivered_units, 0::numeric) AS delivered_units,
            COALESCE(o.ordered_units, 0::numeric) AS ordered_units,
            COALESCE(o.due_units, 0::numeric) AS due_units,
            COALESCE(o.on_time_units, 0::numeric) AS on_time_units,
            o.avg_delivery_days,
            COALESCE(i.sku_count, 0) AS sku_count,
            COALESCE(i.healthy_skus, 0) AS healthy_skus,
            COALESCE(i.inventory_units, 0::numeric) AS inventory_units,
            COALESCE(i.inventory_value, 0::numeric) AS inventory_value,
            COALESCE(i.low_stock_skus, 0) AS low_stock_skus,
            i.inventory_health_score,
            COALESCE(p.produced_units, 0::numeric) AS produced_units,
            COALESCE(p.production_runs, 0) AS production_runs,
            COALESCE(f.revenue, 0::numeric) AS revenue,
            COALESCE(f.operating_cost, 0::numeric) AS operating_cost,
            COALESCE(d.decision_count, 0) AS decision_count,
            COALESCE(d.evaluated_decisions, 0) AS evaluated_decisions,
            d.decision_quality,
            COALESCE((ct.operating_profile ->> 'baseline_lead_time_days'::text)::numeric, 7::numeric) AS baseline_lead_time_days,
            COALESCE((ct.operating_profile ->> 'initial_finished_units'::text)::numeric, 0::numeric) AS initial_finished_units,
            COALESCE((ct.operating_profile ->> 'target_cost_per_unit'::text)::numeric, 0::numeric) AS target_cost_per_unit
           FROM competition_teams t
             JOIN company_templates ct ON ct.id = t.company_template_id
             LEFT JOIN order_metrics o ON o.team_id = t.id
             LEFT JOIN inventory_metrics i ON i.team_id = t.id
             LEFT JOIN production_metrics p ON p.team_id = t.id
             LEFT JOIN finance_metrics f ON f.team_id = t.id
             LEFT JOIN decision_metrics d ON d.team_id = t.id
             LEFT JOIN competition_simulation_clock clk ON clk.competition_id = t.competition_id
        ), scored AS (
         SELECT r.team_id,
            r.competition_id,
            r.classroom_id,
            r.team_name,
            r.starting_capital,
            r.cash_balance,
            r.current_round,
            r.production_capacity_units,
            r.company_name,
            r.scoring_weights,
            r.total_orders,
            r.delivered_orders,
            r.delivered_units,
            r.ordered_units,
            r.due_units,
            r.on_time_units,
            r.avg_delivery_days,
            r.sku_count,
            r.healthy_skus,
            r.inventory_units,
            r.inventory_value,
            r.low_stock_skus,
            r.inventory_health_score,
            r.initial_finished_units,
            r.target_cost_per_unit,
            r.produced_units,
            r.production_runs,
            r.revenue,
            r.operating_cost,
            r.decision_count,
            r.evaluated_decisions,
            r.decision_quality,
            r.baseline_lead_time_days,
                CASE
                    WHEN r.due_units > 0::numeric THEN round(100::numeric * r.on_time_units / r.due_units, 2)
                    ELSE NULL::numeric
                END AS service_score,
                CASE
                    WHEN r.delivered_units > 0::numeric AND r.target_cost_per_unit > 0::numeric AND r.operating_cost > 0::numeric THEN GREATEST(0::numeric, LEAST(100::numeric, round(100::numeric * r.target_cost_per_unit / (r.operating_cost / r.delivered_units), 2)))
                    WHEN r.delivered_units > 0::numeric AND r.operating_cost = 0::numeric THEN 100::numeric
                    ELSE NULL::numeric
                END AS cost_score,
                CASE
                    WHEN r.sku_count > 0 THEN r.inventory_health_score
                    ELSE NULL::numeric
                END AS inventory_score,
                CASE
                    WHEN r.avg_delivery_days > 0::numeric THEN LEAST(100::numeric, round(100::numeric * r.baseline_lead_time_days / r.avg_delivery_days, 2))
                    ELSE NULL::numeric
                END AS lead_time_score,
                CASE
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
                END AS productivity_score,
            round(r.decision_quality, 2) AS decision_quality_score
           FROM raw r
        ), weighted AS (
         SELECT s.team_id,
            s.competition_id,
            s.classroom_id,
            s.team_name,
            s.starting_capital,
            s.cash_balance,
            s.current_round,
            s.production_capacity_units,
            s.company_name,
            s.scoring_weights,
            s.total_orders,
            s.delivered_orders,
            s.delivered_units,
            s.ordered_units,
            s.due_units,
            s.on_time_units,
            s.avg_delivery_days,
            s.sku_count,
            s.healthy_skus,
            s.inventory_units,
            s.inventory_value,
            s.low_stock_skus,
            s.inventory_health_score,
            s.initial_finished_units,
            s.target_cost_per_unit,
            s.produced_units,
            s.production_runs,
            s.revenue,
            s.operating_cost,
            s.decision_count,
            s.evaluated_decisions,
            s.decision_quality,
            s.baseline_lead_time_days,
            s.service_score,
            s.cost_score,
            s.inventory_score,
            s.lead_time_score,
            s.productivity_score,
            s.decision_quality_score,
                CASE
                    WHEN s.service_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.cost_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.inventory_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.lead_time_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.productivity_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric)
                    ELSE 0::numeric
                END +
                CASE
                    WHEN s.decision_quality_score IS NOT NULL THEN COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric)
                    ELSE 0::numeric
                END AS available_weight,
            COALESCE(s.service_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'service'::text)::numeric, 25::numeric) + COALESCE(s.cost_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'cost'::text)::numeric, 20::numeric) + COALESCE(s.inventory_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'inventory'::text)::numeric, 15::numeric) + COALESCE(s.lead_time_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'lead_time'::text)::numeric, 15::numeric) + COALESCE(s.productivity_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'productivity'::text)::numeric, 10::numeric) + COALESCE(s.decision_quality_score, 0::numeric) * COALESCE((s.scoring_weights ->> 'decision_quality'::text)::numeric, 15::numeric) AS weighted_sum
           FROM scored s
        )
 SELECT team_id,
    competition_id,
    classroom_id,
    team_name,
    company_name,
    starting_capital,
    cash_balance,
    total_orders,
    delivered_orders,
    delivered_units,
    on_time_units,
    avg_delivery_days,
    sku_count,
    healthy_skus,
    inventory_units,
    inventory_value,
    low_stock_skus,
    produced_units,
    production_runs,
    revenue,
    operating_cost,
    decision_count,
    evaluated_decisions,
    decision_quality,
    service_score,
    cost_score,
    inventory_score,
    lead_time_score,
    productivity_score,
    decision_quality_score,
    round(available_weight, 2) AS score_coverage_pct,
        CASE
            WHEN delivered_orders > 0 AND evaluated_decisions > 0 AND available_weight > 0::numeric THEN round(weighted_sum / available_weight, 2)
            ELSE NULL::numeric
        END AS total_score,
    jsonb_build_object('service', service_score, 'cost', cost_score, 'inventory', inventory_score, 'lead_time', lead_time_score, 'productivity', productivity_score, 'decision_quality', decision_quality_score) AS component_scores,
    current_round,
    due_units,
    ordered_units,
    initial_finished_units,
    target_cost_per_unit
   FROM weighted;;
alter view public.competition_team_live_metrics set (security_invoker=true);
