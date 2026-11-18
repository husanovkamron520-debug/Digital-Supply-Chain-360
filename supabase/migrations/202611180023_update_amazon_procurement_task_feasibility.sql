
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_create_role_tasks(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'Select Cost-focused (A >=60%), Balanced (A 40–70%) or Service-focused (B+C >=60%).',
  'Choose Cost-focused (A >=60%) or Balanced (A 40–70%). Service-focused (B+C >=60%) is unavailable because B+C combined capacity is only 4,000 of 7,950 net required units (50.3%).');
 execute v_def;
end $migration$;
