-- Security hardening for SECURITY DEFINER helpers.
-- Keep these RPCs available to authenticated users only.
revoke all on function public.create_classroom(text, text) from public, anon;
revoke all on function public.join_classroom(text) from public, anon;
revoke all on function public.current_user_is_teacher() from public, anon;
revoke all on function public.is_class_member(uuid) from public, anon;
revoke all on function public.is_class_teacher(uuid) from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;

grant execute on function public.create_classroom(text, text) to authenticated;
grant execute on function public.join_classroom(text) to authenticated;
grant execute on function public.current_user_is_teacher() to authenticated;
grant execute on function public.is_class_member(uuid) to authenticated;
grant execute on function public.is_class_teacher(uuid) to authenticated;
