-- Amazon Global Combined Crisis pause support prerequisite.
-- The complete operational/security changes are in 202611190002_amazon_case_audit_fixes_replay.sql.
ALTER TABLE public.competitions ADD COLUMN IF NOT EXISTS paused_at timestamptz;
