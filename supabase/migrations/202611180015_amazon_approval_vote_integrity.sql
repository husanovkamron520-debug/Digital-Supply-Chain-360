
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_vote_approval(uuid,text)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'insert into public.amazon_case_approval_votes(approval_id,student_id,vote) values(p_approval_id,(select auth.uid()),p_vote)
 on conflict(approval_id,student_id) do update set vote=excluded.vote,created_at=now();',
  'insert into public.amazon_case_approval_votes(approval_id,student_id,vote) values(p_approval_id,(select auth.uid()),p_vote);');
 execute v_def;

 select pg_get_functiondef('public.amazon_submit_approval(uuid,text,text,jsonb)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'') then raise exception ''This is not an Amazon case team''; end if;',
  ' if not exists(select 1 from public.competitions c where c.id=v_team.competition_id and c.settings->>''case_code''=''amazon-global-combined-crisis'' and c.status=''active'') then raise exception ''Amazon case is not active''; end if;');
 execute v_def;
end $migration$;
