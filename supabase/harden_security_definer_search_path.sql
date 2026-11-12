-- SupplyChain14 SECURITY DEFINER search_path hardening.
-- Keep SECURITY DEFINER where needed for controlled writes/RLS helper lookups,
-- but remove mutable schemas from each function's search_path.
alter function public.adjust_inventory_quantity(uuid, integer, text) set search_path = '';
alter function public.create_classroom(text, text) set search_path = '';
alter function public.create_inventory_item(uuid, text, text, integer, integer) set search_path = '';
alter function public.join_classroom(text) set search_path = '';
alter function public.current_user_is_teacher() set search_path = '';
alter function public.is_class_member(uuid) set search_path = '';
alter function public.is_class_teacher(uuid) set search_path = '';
