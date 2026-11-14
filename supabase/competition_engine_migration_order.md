# Competition Engine SQL application order

These are additive SQL scripts for the current SupplyChain14 Supabase project. They are kept as reviewable source files in this repository; they are not automatically applied by the frontend deploy.

For a fresh database, first apply the platform base schema, then the competition foundation and operational engine:

1. `schema.sql`
2. `competition_engine.sql`
3. `competition_operations.sql`

Then apply the current competition refinements in this order:

4. `company_case_profiles.sql` — Toyota, Amazon, IKEA and Coca-Cola educational profiles, source links and synthetic benchmark values.
5. `competition_rpc_row_loading_fix.sql` — fixes row-loading order, prevents purchase orders arriving after close, and makes leaderboard views security-invoker.
6. `competition_balanced_teams_fix.sql` — fixes UUID collection and requires at least five students per balanced team.
7. `competition_core_role_start_guard.sql` — requires all five operational roles before a competition starts.
8. `company_specific_task_pack.sql` — generates company-specific role tasks.
9. `competition_seven_day_rounds.sql` — sets seven virtual days per round.
10. `competition_five_round_schedule.sql` — makes five rounds cover 28 virtual days with a final delivery window.
11. `competition_production_round_capacity.sql` — enforces aggregate production capacity per round and closes production during the final delivery round.
12. `competition_customer_due_date_clock.sql` — validates due dates against virtual time and the competition's final date; closes order creation in the last round.
13. `competition_customer_price_bounds.sql` — caps order prices to the company benchmark.
14. `competition_supplier_negotiation_bounds.sql` — freezes supplier baselines and enforces bounded negotiation trade-offs.
15. `competition_transport_cost_bounds.sql` — locks the simulation clock before dispatch, closes new dispatches in the final round, bounds freight spend and ETA.
16. `competition_inventory_adjustment_bounds.sql` — limits cycle-count changes to 5% and requires a reason.
17. `competition_kpi_scoring.sql` — installs the normalized scorecard; requires the company target-cost values from step 4.
18. `competition_foreign_key_indexes.sql` — indexes competition foreign keys.

## Historical/intermediate patches

- `competition_round_duration_fix.sql` is an intermediate three-day metadata correction. The later `competition_seven_day_rounds.sql` is authoritative.
- `competition_transport_cost_bounds.sql`, `competition_customer_price_bounds.sql`, `competition_supplier_negotiation_bounds.sql`, and `competition_inventory_adjustment_bounds.sql` supersede earlier versions of their respective RPCs.
- Apply the refinements in the order above. Reapplying an older function snapshot after a later refinement can revert a security or business-rule guard.

## Simulation data disclaimer

The named companies are educational case studies based on public company descriptions. Capacities, costs, supplier terms, stock levels, selling prices and scoring targets are synthetic teaching parameters, not official company data, confidential information or a claim of partnership.
