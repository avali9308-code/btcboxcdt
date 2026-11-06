-- BTCBOX Seconds: retired legacy single-open-position restriction.
-- This numbered file is intentionally retained as a no-op so the four-digit
-- migration sequence remains continuous for existing source tooling.
-- BTCBOX allows each user to hold multiple independent open positions.
-- Do not recreate a per-user partial unique index here.

DO $$
BEGIN
  IF to_regclass('public.seconds_contract_positions_one_open_per_user_idx') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy one-open-position index exists; remove it in the approved fresh-schema bootstrap before enabling Seconds';
  END IF;
END;
$$;
