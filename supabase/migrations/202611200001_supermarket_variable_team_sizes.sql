-- Allow Supermarket Crisis teams to contain additional students beyond the six core roles.
-- Every member still receives an individual task through competition_tasks.assigned_to.
do $migration$
declare
  v_def text;
begin
  select pg_get_functiondef('public.create_balanced_competition_teams(uuid,integer)'::regprocedure) into v_def;
  if position('v_student_count<>p_team_count*v_required' in v_def)>0 then
    v_def := replace(v_def,'v_student_count<>p_team_count*v_required','v_student_count<p_team_count*v_required');
    v_def := replace(v_def,'Supermarket case requires exactly % students','Supermarket case requires at least % students');
    execute v_def;
  elsif position('v_student_count<p_team_count*v_required' in v_def)=0 then
    raise exception 'Unexpected create_balanced_competition_teams definition; migration aborted';
  end if;

  select pg_get_functiondef('public.create_supermarket_role_tasks(uuid)'::regprocedure) into v_def;
  if position('if v_inserted<>6 then' in v_def)>0 then
    v_def := replace(v_def,'if v_inserted<>6 then','if v_inserted<6 then');
    execute v_def;
  elsif position('if v_inserted<6 then' in v_def)=0 then
    raise exception 'Unexpected create_supermarket_role_tasks definition; migration aborted';
  end if;
end
$migration$;
