-- SupplyChain14: enforce database-side role checks for operational writes.
-- All browser writes must go through validated RPCs; direct table DML bypasses role rules.
revoke insert, update, delete on public.orders, public.shipments, public.inventory
  from public, anon, authenticated;
grant select on public.orders, public.shipments, public.inventory to authenticated;
