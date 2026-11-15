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
18. `competition_foreign_key_indexes.sql` — adds missing foreign-key indexes only when no existing index covers the same leading columns.
19. `competition_clock_serialization_guards.sql` — serializes receipts, deliveries, supplier changes, stock counts, task submissions, decision evaluation and round score snapshots against the simulation clock.
20. `competition_member_reassignment.sql` — allows teachers to correct a student's team and operational role before the competition starts.
21. `competition_final_evaluation_guard.sql` — prevents finalisation while any submitted student decision remains unevaluated.
22. `competition_advanced_case_pack.sql` — replaces the short generic role tasks with quantitative, multi-constraint case briefs for Procurement, Supplier, Manufacturer, Warehouse and Transport, each with explicit deliverables and a 100-point rubric.
23. `competition_task_scoring_and_combined_individual_grades.sql` — adds teacher-scored case submissions, role-to-student grade attribution, and an individual leaderboard combining evaluated case tasks with evaluated operational decisions.
24. `competition_case_pack_precision_clarification.sql` — clarifies warehouse inbound/outbound timing and day-by-day overflow-cost comparison, supplier fill/defect calculations, procurement order quantity formula and transport trip/penalty cost assumptions.
25. `competition_task_review_requires_score.sql` — blocks unscored task approval and adds a database constraint requiring every approved case submission to have a numeric grade.
26. `competition_task_finalization_guard.sql` — prevents competition completion until the advanced role case pack exists and every task is approved with a numeric grade.
27. `competition_finalization_requires_all_role_tasks.sql` — additionally requires every team to have all five core role tasks before finalization.
28. `competition_individual_role_case_tasks.sql` — creates one separately assigned case submission per student, including duplicate role holders in teams of six or seven.
29. `competition_weighted_individual_grades.sql` — computes the individual final grade as 50% average of case-task grades and 50% average of evaluated operational decisions.

## Historical/intermediate patches

- `competition_round_duration_fix.sql` is an intermediate three-day metadata correction. The later `competition_seven_day_rounds.sql` is authoritative.
- `competition_transport_cost_bounds.sql`, `competition_customer_price_bounds.sql`, `competition_supplier_negotiation_bounds.sql`, and `competition_inventory_adjustment_bounds.sql` supersede earlier versions of their respective RPCs.
- Apply the refinements in the order above. Reapplying an older function snapshot after a later refinement can revert a security or business-rule guard.
- The live project also has a follow-up migration named `competition_case_pack_calculation_clarity`, which calibrates the advanced case assumptions (defect cost, rush material availability and overflow unit-day costing). The checked-in `competition_advanced_case_pack.sql` is the consolidated current definition and includes those corrections.

## Simulation data disclaimer

The named companies are educational case studies based on public company descriptions. Capacities, costs, supplier terms, stock levels, selling prices and scoring targets are synthetic teaching parameters, not official company data, confidential information or a claim of partnership.
