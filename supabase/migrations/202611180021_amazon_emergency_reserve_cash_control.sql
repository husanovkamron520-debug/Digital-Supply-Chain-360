
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_initialize_team(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,'starting_capital=190000,cash_balance=190000','starting_capital=160000,cash_balance=160000');
 v_def:=replace(v_def,'values(v_team.competition_id,p_team_id,v_team.classroom_id,''capital'',190000,',
  'values(v_team.competition_id,p_team_id,v_team.classroom_id,''capital'',160000,');
 v_def:=replace(v_def,'$30,000 emergency reserve','$30,000 emergency reserve (not released until approved)');
 v_def:=replace(v_def,'''opening_capital'',190000','''opening_capital'',160000,''emergency_reserve'',30000');
 execute v_def;

 select pg_get_functiondef('public.amazon_vote_approval(uuid,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'update public.amazon_case_team_state set reserve_approved=reserve_approved+(v_a.payload->>''amount'')::numeric where team_id=v_a.team_id;',
  'update public.amazon_case_team_state set reserve_approved=reserve_approved+(v_a.payload->>''amount'')::numeric where team_id=v_a.team_id;
   update public.competition_teams set cash_balance=cash_balance+(v_a.payload->>''amount'')::numeric where id=v_a.team_id;
   insert into public.competition_ledger(competition_id,team_id,classroom_id,actor_id,entry_type,amount,description,reference_id)
   select v_a.competition_id,v_a.team_id,t.classroom_id,(select auth.uid()),''adjustment'',
    (v_a.payload->>''amount'')::numeric,''Approved emergency reserve release'',p_approval_id
   from public.competition_teams t where t.id=v_a.team_id;');
 execute v_def;
end $migration$;
