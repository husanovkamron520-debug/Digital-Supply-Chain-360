-- Cover foreign-key columns identified by Supabase Performance Advisor.
create index if not exists classrooms_teacher_id_idx on public.classrooms(teacher_id);
create index if not exists scenarios_created_by_idx on public.scenarios(created_by);
create index if not exists orders_created_by_idx on public.orders(created_by);
create index if not exists orders_scenario_id_idx on public.orders(scenario_id);
create index if not exists shipments_created_by_idx on public.shipments(created_by);
create index if not exists shipments_order_id_idx on public.shipments(order_id);
create index if not exists shipments_scenario_id_idx on public.shipments(scenario_id);
create index if not exists activity_logs_actor_id_idx on public.activity_logs(actor_id);
create index if not exists activity_logs_scenario_id_idx on public.activity_logs(scenario_id);
create index if not exists suppliers_created_by_idx on public.suppliers(created_by);
create index if not exists purchase_orders_created_by_idx on public.purchase_orders(created_by);
create index if not exists purchase_orders_supplier_id_idx on public.purchase_orders(supplier_id);
