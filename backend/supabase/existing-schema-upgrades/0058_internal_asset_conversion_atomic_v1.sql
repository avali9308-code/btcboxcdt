-- 0058_internal_asset_conversion_atomic_v1.sql
-- MANUAL EXISTING-SCHEMA UPGRADE ONLY.
-- Review the production schema and backup before execution. This file is
-- intentionally excluded from empty-database bootstrap and all auto-init flows.
-- It adds one RPC/table and extends one operation-type constraint. It does not
-- create a database, reset data, backfill balances, or touch existing accounts.

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

DO $preflight$
BEGIN
  IF to_regclass('public.financial_accounts') IS NULL
     OR to_regclass('public.financial_operations') IS NULL
     OR to_regclass('public.financial_ledger') IS NULL
     OR to_regclass('public.btcbox_assets') IS NULL THEN
    RAISE EXCEPTION 'BTCBOX existing financial ledger and asset registry are required; no changes applied';
  END IF;
END;
$preflight$;

-- Existing rows are not rewritten. NOT VALID avoids a full-table scan while
-- immediately enforcing the expanded allowlist for newly inserted operations.
DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.financial_operations'::regclass
      AND conname='financial_operations_operation_type_check_v2'
  ) THEN
    ALTER TABLE public.financial_operations
      ADD CONSTRAINT financial_operations_operation_type_check_v2
      CHECK (operation_type IN (
        'deposit_credit','withdraw_freeze','withdraw_approve','withdraw_reject',
        'withdraw_settle','withdraw_paid','earn_subscribe','earn_redeem',
        'admin_adjustment','spot_trade','spot_order_reserve','spot_order_cancel',
        'seconds_open','seconds_settle','migration_opening_balance',
        'perp_order_reserve','perp_trade','perp_order_cancel','perp_funding',
        'perp_liquidation','perp_insurance_cover','perp_bad_debt',
        'asset_conversion'
      )) NOT VALID;
  END IF;
  ALTER TABLE public.financial_operations
    DROP CONSTRAINT IF EXISTS financial_operations_operation_type_check;
  ALTER TABLE public.financial_operations
    RENAME CONSTRAINT financial_operations_operation_type_check_v2
    TO financial_operations_operation_type_check;
  ALTER TABLE public.financial_operations
    VALIDATE CONSTRAINT financial_operations_operation_type_check;
END;
$constraint$;

-- Immutable single-use quote claims. Rows are only inserted by the atomic RPC;
-- no client-facing table privileges are granted.
CREATE TABLE IF NOT EXISTS public.financial_conversion_quotes (
  quote_id uuid PRIMARY KEY,
  operation_id uuid NOT NULL UNIQUE REFERENCES public.financial_operations(id),
  user_id text NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.financial_conversion_quotes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.financial_conversion_quotes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.financial_conversion_quotes TO service_role;

CREATE OR REPLACE FUNCTION public.apply_internal_conversion_atomic(
  p_request_id text,
  p_quote_id uuid,
  p_user_id text,
  p_from_asset text,
  p_to_asset text,
  p_from_amount numeric,
  p_to_amount numeric,
  p_quote_rate numeric,
  p_quote_expires_at bigint,
  p_request_hash text,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_op public.financial_operations%ROWTYPE;
  v_ledger_count integer;
  v_from_available numeric(38,18);
  v_to_available numeric(38,18);
  v_from_decimals smallint;
  v_to_decimals smallint;
  v_locked_asset text;
  v_from_after numeric(38,18);
  v_to_after numeric(38,18);
  v_expiry timestamptz;
BEGIN
  IF p_request_id IS NULL OR length(p_request_id) < 16 OR length(p_request_id) > 128
     OR p_quote_id IS NULL
     OR p_user_id IS NULL OR p_user_id = ''
     OR p_from_asset IS NULL OR p_from_asset !~ '^[A-Z0-9]{2,16}$'
     OR p_to_asset IS NULL OR p_to_asset !~ '^[A-Z0-9]{2,16}$'
     OR p_from_asset = p_to_asset
     OR p_from_amount IS NULL OR p_from_amount <= 0
     OR p_to_amount IS NULL OR p_to_amount <= 0
     OR p_quote_rate IS NULL OR p_quote_rate <= 0
     OR p_quote_expires_at IS NULL OR p_quote_expires_at <= 0
     OR p_request_hash IS NULL OR p_request_hash !~ '^[0-9a-f]{64}
    RAISE EXCEPTION 'invalid internal conversion request';
  END IF;

  -- Serialize retries by request ID. The request hash binds the signed quote
  -- and every monetary input; the same key with changed inputs is rejected.
  INSERT INTO public.financial_operations(
    idempotency_key,user_id,asset,operation_type,request_hash,metadata
  ) VALUES (
    p_request_id,p_user_id,p_from_asset,'asset_conversion',p_request_hash,
    p_metadata || jsonb_build_object(
      'quote_id',p_quote_id,'from_asset',p_from_asset,'to_asset',p_to_asset,
      'from_amount',p_from_amount,'to_amount',p_to_amount,'quote_rate',p_quote_rate,
      'fee_amount',0
    )
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  SELECT * INTO v_op
  FROM public.financial_operations
  WHERE idempotency_key=p_request_id
  FOR UPDATE;

  IF NOT FOUND OR v_op.user_id<>p_user_id OR v_op.asset<>p_from_asset
     OR v_op.operation_type<>'asset_conversion' OR v_op.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'conversion idempotency key payload mismatch';
  END IF;

  SELECT count(*) INTO v_ledger_count
  FROM public.financial_ledger WHERE operation_id=v_op.id;

  IF v_ledger_count > 0 THEN
    IF v_ledger_count <> 2
       OR NOT EXISTS (
         SELECT 1 FROM public.financial_ledger
         WHERE operation_id=v_op.id AND user_id=p_user_id AND asset=p_from_asset
           AND available_delta=-p_from_amount AND frozen_delta=0
       )
       OR NOT EXISTS (
         SELECT 1 FROM public.financial_ledger
         WHERE operation_id=v_op.id AND user_id=p_user_id AND asset=p_to_asset
           AND available_delta=p_to_amount AND frozen_delta=0
       ) THEN
      RAISE EXCEPTION 'conversion ledger invariant failed';
    END IF;
    SELECT available INTO v_from_after FROM public.financial_accounts
      WHERE user_id=p_user_id AND asset=p_from_asset;
    SELECT available INTO v_to_after FROM public.financial_accounts
      WHERE user_id=p_user_id AND asset=p_to_asset;
    RETURN jsonb_build_object(
      'ok',true,'duplicate',true,'operation_id',v_op.id,
      'from_asset',p_from_asset,'to_asset',p_to_asset,
      'from_available',v_from_after,'to_available',v_to_after,
      'from_amount',p_from_amount,'to_amount',p_to_amount
    );
  END IF;

  SELECT decimals INTO v_from_decimals
  FROM public.btcbox_assets
  WHERE asset_code=p_from_asset AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'source asset is not enabled'; END IF;

  SELECT decimals INTO v_to_decimals
  FROM public.btcbox_assets
  WHERE asset_code=p_to_asset AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'destination asset is not enabled'; END IF;

  IF p_from_amount <> trunc(p_from_amount, v_from_decimals)
     OR p_to_amount <> trunc(p_to_amount, v_to_decimals) THEN
    RAISE EXCEPTION 'conversion amount exceeds asset precision';
  END IF;

  IF p_to_amount <> trunc(p_from_amount * p_quote_rate, v_to_decimals) THEN
    RAISE EXCEPTION 'conversion quote amount does not match rate';
  END IF;

  v_expiry := to_timestamp(p_quote_expires_at::double precision / 1000.0);
  IF v_expiry <= clock_timestamp() OR v_expiry > clock_timestamp() + interval '31 seconds' THEN
    RAISE EXCEPTION 'conversion quote expired';
  END IF;

  -- A quote can fund only one conversion request, even if a client submits
  -- the same signed quote under different request IDs.
  INSERT INTO public.financial_conversion_quotes(quote_id,operation_id,user_id,expires_at)
  VALUES (p_quote_id,v_op.id,p_user_id,v_expiry)
  ON CONFLICT (quote_id) DO NOTHING;
  IF NOT FOUND THEN RAISE EXCEPTION 'conversion quote already used'; END IF;

  INSERT INTO public.financial_accounts(user_id,asset)
  VALUES (p_user_id,p_from_asset),(p_user_id,p_to_asset)
  ON CONFLICT (user_id,asset) DO NOTHING;

  -- Always lock the two account rows in asset-code order to avoid deadlocks
  -- when two concurrent conversions run in opposite directions.
  FOR v_locked_asset IN
    SELECT asset FROM public.financial_accounts
    WHERE user_id=p_user_id AND asset IN (p_from_asset,p_to_asset)
    ORDER BY asset
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  SELECT available INTO v_from_available
  FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_from_asset;
  SELECT available INTO v_to_available
  FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_to_asset;

  IF v_from_available < p_from_amount THEN
    RAISE EXCEPTION 'insufficient funds';
  END IF;

  UPDATE public.financial_accounts
  SET available=available-p_from_amount,version=version+1,updated_at=clock_timestamp()
  WHERE user_id=p_user_id AND asset=p_from_asset
  RETURNING available INTO v_from_after;

  UPDATE public.financial_accounts
  SET available=available+p_to_amount,version=version+1,updated_at=clock_timestamp()
  WHERE user_id=p_user_id AND asset=p_to_asset
  RETURNING available INTO v_to_after;

  INSERT INTO public.financial_ledger(
    operation_id,user_id,asset,available_delta,frozen_delta,available_after,frozen_after
  ) VALUES
    (v_op.id,p_user_id,p_from_asset,-p_from_amount,0,v_from_after,
      (SELECT frozen FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_from_asset)),
    (v_op.id,p_user_id,p_to_asset,p_to_amount,0,v_to_after,
      (SELECT frozen FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_to_asset));

  RETURN jsonb_build_object(
    'ok',true,'duplicate',false,'operation_id',v_op.id,
    'from_asset',p_from_asset,'to_asset',p_to_asset,
    'from_available',v_from_after,'to_available',v_to_after,
    'from_amount',p_from_amount,'to_amount',p_to_amount
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) TO service_role;

COMMENT ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) IS 'Atomic two-asset conversion using the existing BTCBOX financial accounts and ledger. Manual existing-schema upgrade only; signed quotes are single-use and request retries are idempotent.';

COMMIT;

     OR p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' THEN
    RAISE EXCEPTION 'invalid internal conversion request';
  END IF;

  SELECT decimals INTO v_from_decimals
  FROM public.btcbox_assets
  WHERE asset_code=p_from_asset AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'source asset is not enabled'; END IF;

  SELECT decimals INTO v_to_decimals
  FROM public.btcbox_assets
  WHERE asset_code=p_to_asset AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'destination asset is not enabled'; END IF;

  IF p_from_amount <> trunc(p_from_amount, v_from_decimals)
     OR p_to_amount <> trunc(p_to_amount, v_to_decimals) THEN
    RAISE EXCEPTION 'conversion amount exceeds asset precision';
  END IF;

  -- Serialize retries by request ID. The request hash binds the signed quote
  -- and every monetary input; the same key with changed inputs is rejected.
  INSERT INTO public.financial_operations(
    idempotency_key,user_id,asset,operation_type,request_hash,metadata
  ) VALUES (
    p_request_id,p_user_id,p_from_asset,'asset_conversion',p_request_hash,
    p_metadata || jsonb_build_object(
      'quote_id',p_quote_id,'from_asset',p_from_asset,'to_asset',p_to_asset,
      'from_amount',p_from_amount,'to_amount',p_to_amount,'quote_rate',p_quote_rate,
      'fee_amount',0
    )
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  SELECT * INTO v_op
  FROM public.financial_operations
  WHERE idempotency_key=p_request_id
  FOR UPDATE;

  IF NOT FOUND OR v_op.user_id<>p_user_id OR v_op.asset<>p_from_asset
     OR v_op.operation_type<>'asset_conversion' OR v_op.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'conversion idempotency key payload mismatch';
  END IF;

  SELECT count(*) INTO v_ledger_count
  FROM public.financial_ledger WHERE operation_id=v_op.id;

  IF v_ledger_count > 0 THEN
    IF v_ledger_count <> 2
       OR NOT EXISTS (
         SELECT 1 FROM public.financial_ledger
         WHERE operation_id=v_op.id AND user_id=p_user_id AND asset=p_from_asset
           AND available_delta=-p_from_amount AND frozen_delta=0
       )
       OR NOT EXISTS (
         SELECT 1 FROM public.financial_ledger
         WHERE operation_id=v_op.id AND user_id=p_user_id AND asset=p_to_asset
           AND available_delta=p_to_amount AND frozen_delta=0
       ) THEN
      RAISE EXCEPTION 'conversion ledger invariant failed';
    END IF;
    SELECT available INTO v_from_after FROM public.financial_accounts
      WHERE user_id=p_user_id AND asset=p_from_asset;
    SELECT available INTO v_to_after FROM public.financial_accounts
      WHERE user_id=p_user_id AND asset=p_to_asset;
    RETURN jsonb_build_object(
      'ok',true,'duplicate',true,'operation_id',v_op.id,
      'from_asset',p_from_asset,'to_asset',p_to_asset,
      'from_available',v_from_after,'to_available',v_to_after,
      'from_amount',p_from_amount,'to_amount',p_to_amount
    );
  END IF;

  v_expiry := to_timestamp(p_quote_expires_at::numeric / 1000);
  IF v_expiry <= clock_timestamp() OR v_expiry > clock_timestamp() + interval '31 seconds' THEN
    RAISE EXCEPTION 'conversion quote expired';
  END IF;

  -- A quote can fund only one conversion request, even if a client submits
  -- the same signed quote under different request IDs.
  INSERT INTO public.financial_conversion_quotes(quote_id,operation_id,user_id,expires_at)
  VALUES (p_quote_id,v_op.id,p_user_id,v_expiry)
  ON CONFLICT (quote_id) DO NOTHING;
  IF NOT FOUND THEN RAISE EXCEPTION 'conversion quote already used'; END IF;

  INSERT INTO public.financial_accounts(user_id,asset)
  VALUES (p_user_id,p_from_asset),(p_user_id,p_to_asset)
  ON CONFLICT (user_id,asset) DO NOTHING;

  -- Always lock the two account rows in asset-code order to avoid deadlocks
  -- when two concurrent conversions run in opposite directions.
  FOR v_locked_asset IN
    SELECT asset FROM public.financial_accounts
    WHERE user_id=p_user_id AND asset IN (p_from_asset,p_to_asset)
    ORDER BY asset
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  SELECT available INTO v_from_available
  FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_from_asset;
  SELECT available INTO v_to_available
  FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_to_asset;

  IF v_from_available < p_from_amount THEN
    RAISE EXCEPTION 'insufficient funds';
  END IF;

  UPDATE public.financial_accounts
  SET available=available-p_from_amount,version=version+1,updated_at=clock_timestamp()
  WHERE user_id=p_user_id AND asset=p_from_asset
  RETURNING available INTO v_from_after;

  UPDATE public.financial_accounts
  SET available=available+p_to_amount,version=version+1,updated_at=clock_timestamp()
  WHERE user_id=p_user_id AND asset=p_to_asset
  RETURNING available INTO v_to_after;

  INSERT INTO public.financial_ledger(
    operation_id,user_id,asset,available_delta,frozen_delta,available_after,frozen_after
  ) VALUES
    (v_op.id,p_user_id,p_from_asset,-p_from_amount,0,v_from_after,
      (SELECT frozen FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_from_asset)),
    (v_op.id,p_user_id,p_to_asset,p_to_amount,0,v_to_after,
      (SELECT frozen FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_to_asset));

  RETURN jsonb_build_object(
    'ok',true,'duplicate',false,'operation_id',v_op.id,
    'from_asset',p_from_asset,'to_asset',p_to_asset,
    'from_available',v_from_after,'to_available',v_to_after,
    'from_amount',p_from_amount,'to_amount',p_to_amount
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) TO service_role;

COMMENT ON FUNCTION public.apply_internal_conversion_atomic(
  text,uuid,text,text,text,numeric,numeric,numeric,bigint,text,jsonb
) IS 'Atomic two-asset conversion using the existing BTCBOX financial accounts and ledger. Manual existing-schema upgrade only; signed quotes are single-use and request retries are idempotent.';

COMMIT;
