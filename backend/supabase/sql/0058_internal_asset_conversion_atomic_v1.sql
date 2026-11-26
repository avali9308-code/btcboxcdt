-- 0055_internal_asset_conversion_atomic_v1.sql
-- Adds an atomic, idempotent same-user asset conversion primitive.
-- This migration is code-only until explicitly reviewed and applied to the database.

ALTER TABLE public.financial_operations
  DROP CONSTRAINT IF EXISTS financial_operations_operation_type_check;

ALTER TABLE public.financial_operations
  ADD CONSTRAINT financial_operations_operation_type_check
  CHECK (operation_type IN (
    'deposit_credit','withdraw_freeze','withdraw_approve','withdraw_reject',
    'withdraw_paid','earn_subscribe','earn_redeem','admin_adjustment',
    'spot_trade','spot_order_reserve','spot_order_cancel','seconds_open',
    'seconds_settle','migration_opening_balance','internal_convert'
  ));

CREATE OR REPLACE FUNCTION public.apply_internal_conversion_atomic(
  p_request_id text,
  p_user_id text,
  p_from_asset text,
  p_to_asset text,
  p_from_amount numeric,
  p_to_amount numeric,
  p_quote_rate numeric,
  p_request_hash text,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_op public.financial_operations%rowtype;
  v_from_available numeric(38,18);
  v_to_available numeric(38,18);
  v_from_frozen numeric(38,18);
  v_to_frozen numeric(38,18);
BEGIN
  IF p_request_id IS NULL OR length(p_request_id) < 16 OR length(p_request_id) > 128
     OR p_user_id IS NULL OR p_user_id = ''
     OR p_from_asset IS NULL OR p_from_asset !~ '^[A-Z0-9]{2,16}$'
     OR p_to_asset IS NULL OR p_to_asset !~ '^[A-Z0-9]{2,16}$'
     OR p_from_asset = p_to_asset
     OR p_from_amount IS NULL OR p_from_amount <= 0
     OR p_to_amount IS NULL OR p_to_amount <= 0
     OR p_quote_rate IS NULL OR p_quote_rate <= 0
     OR p_request_hash IS NULL OR p_request_hash = ''
     OR p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' THEN
    RAISE EXCEPTION 'invalid internal conversion request';
  END IF;

  INSERT INTO public.financial_operations(
    idempotency_key,user_id,asset,operation_type,request_hash,metadata
  ) VALUES (
    'convert:' || p_request_id,p_user_id,p_from_asset,'internal_convert',
    p_request_hash,p_metadata || jsonb_build_object(
      'from_asset',p_from_asset,'to_asset',p_to_asset,
      'from_amount',p_from_amount,'to_amount',p_to_amount,'quote_rate',p_quote_rate
    )
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  SELECT * INTO v_op
  FROM public.financial_operations
  WHERE idempotency_key='convert:' || p_request_id
  FOR UPDATE;

  IF v_op.user_id <> p_user_id OR v_op.asset <> p_from_asset
     OR v_op.operation_type <> 'internal_convert' OR v_op.request_hash <> p_request_hash THEN
    RAISE EXCEPTION 'idempotency key payload mismatch';
  END IF;

  IF EXISTS (SELECT 1 FROM public.financial_ledger WHERE operation_id=v_op.id) THEN
    SELECT available INTO v_from_available
      FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_from_asset;
    SELECT available INTO v_to_available
      FROM public.financial_accounts WHERE user_id=p_user_id AND asset=p_to_asset;
    RETURN jsonb_build_object(
      'ok',true,'duplicate',true,'operation_id',v_op.id,
      'from_available',v_from_available,'to_available',v_to_available
    );
  END IF;

  INSERT INTO public.financial_accounts(user_id,asset)
    VALUES (p_user_id,p_from_asset),(p_user_id,p_to_asset)
    ON CONFLICT DO NOTHING;

  -- Lock both wallets in deterministic asset order to avoid cross-conversion deadlocks.
  PERFORM 1 FROM public.financial_accounts
    WHERE user_id=p_user_id AND asset IN (p_from_asset,p_to_asset)
    ORDER BY asset
    FOR UPDATE;

  SELECT available,frozen INTO v_from_available,v_from_frozen
    FROM public.financial_accounts
    WHERE user_id=p_user_id AND asset=p_from_asset;
  SELECT available,frozen INTO v_to_available,v_to_frozen
    FROM public.financial_accounts
    WHERE user_id=p_user_id AND asset=p_to_asset;

  IF v_from_available < p_from_amount THEN
    RAISE EXCEPTION 'insufficient funds';
  END IF;

  UPDATE public.financial_accounts
    SET available=available-p_from_amount,version=version+1,updated_at=now()
    WHERE user_id=p_user_id AND asset=p_from_asset
    RETURNING available INTO v_from_available;

  UPDATE public.financial_accounts
    SET available=available+p_to_amount,version=version+1,updated_at=now()
    WHERE user_id=p_user_id AND asset=p_to_asset
    RETURNING available INTO v_to_available;

  INSERT INTO public.financial_ledger(
    operation_id,user_id,asset,available_delta,frozen_delta,available_after,frozen_after
  ) VALUES
    (v_op.id,p_user_id,p_from_asset,-p_from_amount,0,v_from_available,v_from_frozen),
    (v_op.id,p_user_id,p_to_asset,p_to_amount,0,v_to_available,v_to_frozen);

  RETURN jsonb_build_object(
    'ok',true,'duplicate',false,'operation_id',v_op.id,
    'from_available',v_from_available,'to_available',v_to_available
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_internal_conversion_atomic(
  text,text,text,text,numeric,numeric,numeric,text,jsonb
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_internal_conversion_atomic(
  text,text,text,text,numeric,numeric,numeric,text,jsonb
) TO service_role;
