
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.initialize_competition_rounds()'::regprocedure) into v_def;
 v_def:=replace(v_def,'make_interval(days=case','make_interval(days=>case');
 execute v_def;
end $migration$;
