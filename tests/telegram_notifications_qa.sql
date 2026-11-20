\set ON_ERROR_STOP on

-- Minimal Supabase-compatible schemas in an isolated PostgreSQL service.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text
);

CREATE TABLE IF NOT EXISTS public.competitions (
  id uuid PRIMARY KEY,
  title text NOT NULL,
  status text NOT NULL
);
CREATE TABLE IF NOT EXISTS public.competition_team_members (
  competition_id uuid NOT NULL,
  student_id uuid NOT NULL,
  team_id uuid NOT NULL
);
CREATE TABLE IF NOT EXISTS public.competition_tasks (
  id uuid PRIMARY KEY,
  competition_id uuid NOT NULL,
  team_id uuid NOT NULL,
  assigned_to uuid,
  status text NOT NULL,
  title text NOT NULL,
  due_at timestamptz,
  review_note text
);
CREATE TABLE IF NOT EXISTS public.competition_rounds (
  id uuid PRIMARY KEY,
  competition_id uuid NOT NULL,
  status text NOT NULL,
  round_number integer NOT NULL,
  title text NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END
$$;

-- This migration must create the private schema and Telegram account table itself.
\i supabase/migrations/20261117190000_telegram_email_registration.sql
\i supabase/migrations/202611200001_supplychain14_telegram_notifications.sql

INSERT INTO auth.users(id) VALUES ('11111111-1111-4111-8111-111111111111');
INSERT INTO public.profiles(id, full_name)
VALUES ('11111111-1111-4111-8111-111111111111', 'QA Student');

SELECT public.create_telegram_registration_pending(
  repeat('a', 64), 987654321, 'qa_user', 'QA Student'
);
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', false);

DO $$
DECLARE
  resolved_user text;
  registration_result jsonb;
BEGIN
  resolved_user := public.get_telegram_registration_user_id(repeat('a', 64));
  IF resolved_user <> '11111111-1111-4111-8111-111111111111' THEN
    RAISE EXCEPTION 'Telegram registration token resolved to the wrong user';
  END IF;
  registration_result := public.complete_telegram_registration(repeat('a', 64));
  IF registration_result ->> 'telegram_linked' <> 'true' THEN
    RAISE EXCEPTION 'Telegram registration did not complete';
  END IF;
  IF EXISTS (
    SELECT 1 FROM private.telegram_registration_pending
    WHERE token_hash = extensions.digest(repeat('a', 64), 'sha256')
  ) THEN
    RAISE EXCEPTION 'Registration token was not consumed';
  END IF;
END
$$;

SELECT public.create_telegram_password_recovery_pending(repeat('b', 64), 987654321);
DO $$
DECLARE
  claim jsonb;
  second_claim_rejected boolean := false;
BEGIN
  claim := public.consume_telegram_password_recovery(repeat('b', 64));
  IF claim ->> 'user_id' <> '11111111-1111-4111-8111-111111111111'
     OR claim ->> 'telegram_user_id' <> '987654321' THEN
    RAISE EXCEPTION 'Password recovery token resolved to the wrong account';
  END IF;
  BEGIN
    PERFORM public.consume_telegram_password_recovery(repeat('b', 64));
  EXCEPTION WHEN OTHERS THEN
    second_claim_rejected := true;
  END;
  IF NOT second_claim_rejected THEN
    RAISE EXCEPTION 'Password recovery token was not single-use';
  END IF;
END
$$;

UPDATE private.telegram_notification_config
SET secret_hash = extensions.digest('supplychain14-qa-secret', 'sha256')
WHERE singleton = true;

INSERT INTO public.competitions(id, title, status)
VALUES ('22222222-2222-4222-8222-222222222222', 'Synthetic Telegram QA', 'draft');
INSERT INTO public.competition_team_members(competition_id, student_id, team_id)
VALUES (
  '22222222-2222-4222-8222-222222222222',
  '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333'
);

UPDATE public.competitions
SET status = 'active'
WHERE id = '22222222-2222-4222-8222-222222222222';

DO $$
DECLARE
  first_batch jsonb;
  second_batch jsonb;
  retry_batch jsonb;
  after_ack jsonb;
  notification_id uuid;
BEGIN
  first_batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(first_batch) <> 1 THEN
    RAISE EXCEPTION 'Expected one competition-start notification, got %', jsonb_array_length(first_batch);
  END IF;
  notification_id := (first_batch -> 0 ->> 'id')::uuid;

  second_batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(second_batch) <> 0 THEN
    RAISE EXCEPTION 'A leased notification was returned to a second poll';
  END IF;

  UPDATE private.telegram_notification_queue
  SET claimed_until = now() - interval '1 second'
  WHERE id = notification_id;
  retry_batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(retry_batch) <> 1 THEN
    RAISE EXCEPTION 'An expired notification lease was not retried';
  END IF;

  IF NOT public.ack_telegram_competition_notification('supplychain14-qa-secret', notification_id) THEN
    RAISE EXCEPTION 'Notification acknowledgement failed';
  END IF;
  after_ack := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(after_ack) <> 0 THEN
    RAISE EXCEPTION 'Acknowledged notification was returned again';
  END IF;
END
$$;

INSERT INTO public.competition_tasks(id, competition_id, team_id, assigned_to, status, title, due_at)
VALUES (
  '44444444-4444-4444-8444-444444444444',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '11111111-1111-4111-8111-111111111111',
  'submitted',
  'Synthetic role task',
  now() + interval '1 hour'
);

DO $$
DECLARE
  batch jsonb;
  notification_id uuid;
BEGIN
  batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(batch) <> 1 THEN
    RAISE EXCEPTION 'Expected one task notification, got %', jsonb_array_length(batch);
  END IF;
  notification_id := (batch -> 0 ->> 'id')::uuid;
  PERFORM public.ack_telegram_competition_notification('supplychain14-qa-secret', notification_id);
END
$$;

UPDATE public.competition_tasks
SET status = 'approved', review_note = 'Synthetic QA approved'
WHERE id = '44444444-4444-4444-8444-444444444444';

DO $$
DECLARE
  batch jsonb;
  notification_id uuid;
BEGIN
  batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(batch) <> 1 THEN
    RAISE EXCEPTION 'Expected one task-review notification, got %', jsonb_array_length(batch);
  END IF;
  notification_id := (batch -> 0 ->> 'id')::uuid;
  PERFORM public.ack_telegram_competition_notification('supplychain14-qa-secret', notification_id);
END
$$;

INSERT INTO public.competition_rounds(id, competition_id, status, round_number, title)
VALUES (
  '55555555-5555-4555-8555-555555555555',
  '22222222-2222-4222-8222-222222222222',
  'active',
  1,
  'Synthetic Round 1'
);

DO $$
DECLARE
  batch jsonb;
  notification_id uuid;
BEGIN
  batch := public.fetch_telegram_competition_notifications('supplychain14-qa-secret');
  IF jsonb_array_length(batch) <> 1 THEN
    RAISE EXCEPTION 'Expected one round notification, got %', jsonb_array_length(batch);
  END IF;
  notification_id := (batch -> 0 ->> 'id')::uuid;
  PERFORM public.ack_telegram_competition_notification('supplychain14-qa-secret', notification_id);
END
$$;

SELECT 'PASS: Telegram registration, recovery, notification triggers, lease, retry, and acknowledgement tests' AS result;
