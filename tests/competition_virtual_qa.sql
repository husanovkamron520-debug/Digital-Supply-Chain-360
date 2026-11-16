\set ON_ERROR_STOP on
BEGIN;

-- Synthetic identities only. Everything is rolled back after assertions.
INSERT INTO auth.users
  (id, aud, role, email, encrypted_password, email_confirmed_at,
   raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  (md5('supplychain14-qa-teacher')::uuid, 'authenticated', 'authenticated',
   'qa.teacher@example.invalid', '', now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"full_name":"QA Teacher"}'::jsonb, now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users
  (id, aud, role, email, encrypted_password, email_confirmed_at,
   raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT md5('supplychain14-qa-student:' || n)::uuid,
       'authenticated', 'authenticated',
       format('qa.student.%s@example.invalid', n), '', now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       jsonb_build_object('full_name', format('Virtual Student %s', n)), now(), now()
FROM generate_series(1, 20) AS n
ON CONFLICT (id) DO NOTHING;

UPDATE public.profiles
SET platform_role = 'teacher', full_name = 'QA Teacher'
WHERE id = md5('supplychain14-qa-teacher')::uuid;

INSERT INTO public.classrooms (id, teacher_id, name, join_code)
SELECT md5('supplychain14-qa-class:' || cohort)::uuid,
       md5('supplychain14-qa-teacher')::uuid,
       format('QA Virtual Cohort %s', cohort),
       format('QA%sTEST', cohort)
FROM (VALUES (15), (16), (19), (20)) AS cohorts(cohort)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.classroom_members (classroom_id, student_id, operational_role)
SELECT md5('supplychain14-qa-class:' || cohort)::uuid,
       md5('supplychain14-qa-student:' || student_no)::uuid,
       'customer'
FROM (VALUES (15), (16), (19), (20)) AS cohorts(cohort)
CROSS JOIN LATERAL generate_series(1, cohort) AS students(student_no)
ON CONFLICT (classroom_id, student_id) DO NOTHING;

-- Prepare the minimum-roster rejection fixture with database-owner privileges;
-- client roles intentionally cannot insert classroom_members directly.
INSERT INTO public.classrooms (id, teacher_id, name, join_code)
VALUES (
  md5('supplychain14-qa-minimum-guard')::uuid,
  md5('supplychain14-qa-teacher')::uuid,
  'QA Minimum Roster Guard',
  'QAGUARD'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.classroom_members (classroom_id, student_id, operational_role)
SELECT md5('supplychain14-qa-minimum-guard')::uuid,
       md5('supplychain14-qa-student:' || n)::uuid,
       'customer'
FROM generate_series(1, 14) AS students(n)
ON CONFLICT (classroom_id, student_id) DO NOTHING;

SELECT set_config('qa.scenario', :'scenario', true);
SELECT set_config('request.jwt.claim.sub', md5('supplychain14-qa-teacher')::uuid::text, true);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', md5('supplychain14-qa-teacher')::uuid::text,
    'role', 'authenticated',
    'aud', 'authenticated'
  )::text,
  true
);

SET LOCAL ROLE authenticated;

DO $qa$
DECLARE
  v_scenario text := current_setting('qa.scenario', true);
  v_case record;
  v_classroom_id uuid;
  v_competition_id uuid;
  v_team_count integer;
  v_min_team_size integer;
  v_max_team_size integer;
  v_bad_role_teams integer;
  v_assigned_students integer;
  v_guard_class uuid;
  v_guard_comp uuid;
  v_rejected boolean;
BEGIN
  FOR v_case IN
    SELECT * FROM (VALUES (15, 3), (16, 3), (19, 3), (20, 4)) AS scenarios(student_count, team_count)
    WHERE v_scenario = 'full' OR student_count::text = v_scenario
  LOOP
    SELECT id INTO v_classroom_id
    FROM public.classrooms
    WHERE join_code = format('QA%sTEST', v_case.student_count);

    IF v_classroom_id IS NULL THEN
      RAISE EXCEPTION 'Missing QA classroom for % students', v_case.student_count;
    END IF;

    v_competition_id := public.create_competition(
      v_classroom_id,
      format('Virtual QA %s students', v_case.student_count),
      '{"round_count":5,"round_duration_minutes":20}'::jsonb
    );

    PERFORM public.create_balanced_competition_teams(v_competition_id, v_case.team_count);

    SELECT count(*) INTO v_team_count
    FROM public.competition_teams
    WHERE competition_id = v_competition_id;

    SELECT count(*) INTO v_assigned_students
    FROM public.competition_team_members
    WHERE competition_id = v_competition_id;

    SELECT min(team_size), max(team_size)
      INTO v_min_team_size, v_max_team_size
    FROM (
      SELECT count(*)::integer AS team_size
      FROM public.competition_team_members
      WHERE competition_id = v_competition_id
      GROUP BY team_id
    ) sizes;

    SELECT count(*) INTO v_bad_role_teams
    FROM public.competition_teams t
    WHERE t.competition_id = v_competition_id
      AND (
        SELECT count(DISTINCT m.operational_role)
        FROM public.competition_team_members m
        WHERE m.competition_id = t.competition_id
          AND m.team_id = t.id
          AND m.operational_role IN ('procurement','supplier','manufacturer','warehouse','transport')
      ) < 5;

    IF v_team_count <> v_case.team_count THEN
      RAISE EXCEPTION 'Expected % teams for % students; got %',
        v_case.team_count, v_case.student_count, v_team_count;
    END IF;
    IF v_assigned_students <> v_case.student_count THEN
      RAISE EXCEPTION 'Expected % assigned students; got %',
        v_case.student_count, v_assigned_students;
    END IF;
    IF v_min_team_size < 5 OR v_max_team_size - v_min_team_size > 1 THEN
      RAISE EXCEPTION 'Unbalanced roster for % students: min %, max %',
        v_case.student_count, v_min_team_size, v_max_team_size;
    END IF;
    IF v_bad_role_teams <> 0 THEN
      RAISE EXCEPTION '% teams lack one or more of the five core roles',
        v_bad_role_teams;
    END IF;

    RAISE NOTICE 'PASS roster=% teams=% sizes=%..% role_coverage=5/5',
      v_case.student_count, v_team_count, v_min_team_size, v_max_team_size;
  END LOOP;

  -- Fourteen students cannot be split into three teams with five required roles each.
  SELECT id INTO v_guard_class
  FROM public.classrooms
  WHERE join_code = 'QAGUARD';
  v_guard_comp := public.create_competition(v_guard_class, 'QA minimum guard', '{}'::jsonb);
  v_rejected := false;
  BEGIN
    PERFORM public.create_balanced_competition_teams(v_guard_comp, 3);
  EXCEPTION WHEN OTHERS THEN
    IF position('At least five students per team' IN SQLERRM) > 0 THEN
      v_rejected := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Minimum roster guard failed: 14 students accepted for 3 teams';
  END IF;
  RAISE NOTICE 'PASS minimum_roster_guard=14 students rejected for 3 teams';
END;
$qa$;

DO $permissions$
BEGIN
  IF has_function_privilege('anon', 'public.create_balanced_competition_teams(uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can execute create_balanced_competition_teams';
  END IF;
  IF has_function_privilege('anon', 'public.evaluate_competition_task(uuid,numeric,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon can execute evaluate_competition_task';
  END IF;
  RAISE NOTICE 'PASS anonymous_rpc_permissions';
END;
$permissions$;

ROLLBACK;
