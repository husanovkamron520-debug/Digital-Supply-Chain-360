-- Least-privilege grants for every exposed public table.
-- All operational mutations go through role-checked SECURITY DEFINER RPCs.
revoke all on all tables in schema public from public, anon, authenticated;

grant select on public.profiles,
  public.classrooms,
  public.classroom_members,
  public.scenarios,
  public.scenario_decisions,
  public.orders,
  public.shipments,
  public.inventory,
  public.activity_logs,
  public.suppliers,
  public.purchase_orders
to authenticated;

-- Users may edit only their own display name; platform_role is immutable to clients.
grant update (full_name) on public.profiles to authenticated;

-- Teachers may assign a student's operational role; no other membership fields are client-writable.
grant update (operational_role) on public.classroom_members to authenticated;
