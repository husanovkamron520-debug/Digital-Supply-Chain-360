-- Remove inherited/default table grants as well as direct DML grants.
-- Browser clients read through authenticated RLS; all writes use validated RPCs.
revoke all on public.orders, public.shipments, public.inventory
  from public, anon, authenticated;
grant select on public.orders, public.shipments, public.inventory to authenticated;
