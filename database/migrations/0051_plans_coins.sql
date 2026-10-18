-- Plans, coins and purchases (docs/architecture/11-plans-and-entitlements.md, docs/api/28-billing.md).
--
-- 1. coin_balances / coin_ledger: a member's coins. The ledger is append-only (a spend or a refund is a new row, never an
--    edit) and every row carries an idempotency key, so a replayed purchase, reward or spend changes nothing twice.
--    coin_balances.balance has CHECK (balance >= 0): a spend that would go below zero fails in the database, whatever the
--    application does. Both are kept in step inside one transaction, behind a per-member advisory lock (store/coins.go).
-- 2. purchases: one row per store transaction. The transaction id is stored only as a SHA-256 hash (tx_hash, UNIQUE), so a
--    purchase can be granted once and found again from a store notification, and no receipt or token is ever stored.
-- 3. subscriptions: a member's Premium subscription as the store last told us (status, period end, grace). original_hash is
--    the hash of the subscription's original transaction / purchase token and is UNIQUE.
-- 4. ad_reward_sessions: one row per rewarded ad the app started (the nonce is sent to AdMob as custom data and comes
--    back, signed by Google, in the server-side verification callback). Coins are credited from the callback only.
-- 5. profile_detail_unlocks: a member paid coins to see another member's detailed profile fields for a while.
-- 6. coin_admin_adjust: the one way a person changes a balance by hand (support). It writes the ledger and the operator
--    audit in one transaction, and refuses a missing actor or reason. Not granted to any application role: run it as the
--    table owner (docs/api/28-billing.md, "Support adjustments").

CREATE TABLE coin_balances (
  user_id uuid PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE coin_ledger (
  entry_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  delta integer NOT NULL CHECK (delta <> 0),
  reason text NOT NULL CHECK (reason IN ('purchase','reward_ad','profile_completion','review_bonus','spend_chat_slot','spend_profile_detail','refund','refund_reversal','admin_adjust')),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200),
  ref text CHECK (ref IS NULL OR length(ref) <= 120),
  balance_after bigint NOT NULL CHECK (balance_after >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT coin_ledger_idempotency UNIQUE (idempotency_key),
  CONSTRAINT coin_ledger_sign CHECK (
       (reason IN ('spend_chat_slot','spend_profile_detail','refund') AND delta < 0)
    OR (reason IN ('purchase','reward_ad','profile_completion','review_bonus','refund_reversal') AND delta > 0)
    OR reason = 'admin_adjust')
);
CREATE INDEX coin_ledger_user ON coin_ledger (user_id, entry_id DESC);

-- Append-only. A row leaves only with its member: through ON DELETE CASCADE from users (the trigger then runs at depth 2), or through
-- purge_member_billing below (the account purge), which names the member in a transaction-local setting. A direct UPDATE or DELETE
-- anywhere else is refused (the API role has no TRUNCATE, which would also bypass this).
CREATE FUNCTION coin_ledger_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND (pg_trigger_depth() > 1 OR OLD.user_id::text = current_setting('hiyall.purging_member', true)) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'coin_ledger is append-only' USING ERRCODE = '55000';
END
$$;
CREATE TRIGGER coin_ledger_no_change BEFORE UPDATE OR DELETE ON coin_ledger
  FOR EACH ROW EXECUTE FUNCTION coin_ledger_append_only();

CREATE TABLE purchases (
  purchase_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  store text NOT NULL CHECK (store IN ('google_play','app_store')),
  tx_hash text NOT NULL CHECK (tx_hash ~ '^[0-9a-f]{64}$'),
  product_id text NOT NULL CHECK (length(product_id) BETWEEN 1 AND 100),
  kind text NOT NULL CHECK (kind IN ('coins','subscription')),
  state text NOT NULL CHECK (state IN ('pending','verified','refunded','revoked')),
  coins integer NOT NULL DEFAULT 0 CHECK (coins >= 0),
  coins_reversed integer NOT NULL DEFAULT 0 CHECK (coins_reversed >= 0 AND coins_reversed <= coins),
  test_purchase boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  verified_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchases_tx_hash UNIQUE (tx_hash)
);
CREATE INDEX purchases_user ON purchases (user_id, created_at DESC);

CREATE TABLE subscriptions (
  subscription_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  plan text NOT NULL CHECK (plan IN ('premium')),
  store text NOT NULL CHECK (store IN ('google_play','app_store')),
  product_id text NOT NULL CHECK (length(product_id) BETWEEN 1 AND 100),
  status text NOT NULL CHECK (status IN ('active','grace','on_hold','paused','expired','revoked')),
  current_period_end timestamptz NOT NULL,
  grace_until timestamptz,
  auto_renew boolean NOT NULL DEFAULT false,
  original_hash text NOT NULL CHECK (original_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscriptions_original UNIQUE (original_hash)
);
CREATE INDEX subscriptions_user ON subscriptions (user_id, current_period_end DESC);

CREATE TABLE ad_reward_sessions (
  nonce uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','credited','rejected')),
  coins integer NOT NULL DEFAULT 0 CHECK (coins >= 0),
  ssv_hash text CHECK (ssv_hash IS NULL OR ssv_hash ~ '^[0-9a-f]{64}$'),
  credited_at timestamptz,
  reject_reason text CHECK (reject_reason IS NULL OR length(reject_reason) <= 40),
  CONSTRAINT ad_reward_sessions_ssv UNIQUE (ssv_hash)
);
CREATE INDEX ad_reward_sessions_user ON ad_reward_sessions (user_id, created_at DESC);
CREATE INDEX ad_reward_sessions_created ON ad_reward_sessions (created_at);

CREATE TABLE profile_detail_unlocks (
  viewer_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  target_id uuid NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  unlocked_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (viewer_id, target_id)
);
CREATE INDEX profile_detail_unlocks_expires ON profile_detail_unlocks (expires_at);

-- 6. Support adjustment. Positive p_delta gives coins, negative takes them (never below zero: the CHECK refuses).
CREATE FUNCTION coin_admin_adjust(p_user uuid, p_delta integer, p_actor text, p_reason text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE bal bigint; entry bigint;
BEGIN
  IF btrim(coalesce(p_actor, '')) = '' OR btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'coin_admin_adjust needs an actor and a reason' USING ERRCODE = '22023';
  END IF;
  IF p_delta = 0 THEN
    RAISE EXCEPTION 'coin_admin_adjust needs a non-zero delta' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_user) THEN
    RAISE EXCEPTION 'no such member' USING ERRCODE = 'P0002';
  END IF;
  -- The same lock the API takes for this member's coins (store/coins.go lockCoins), so an adjustment waits for a spend.
  PERFORM pg_advisory_xact_lock(hashtextextended('coins' || chr(31) || p_user::text, 0));
  INSERT INTO coin_balances(user_id, balance) VALUES (p_user, 0) ON CONFLICT (user_id) DO NOTHING;
  UPDATE coin_balances SET balance = balance + p_delta, updated_at = now() WHERE user_id = p_user RETURNING balance INTO bal;
  INSERT INTO coin_ledger(user_id, delta, reason, idempotency_key, ref, balance_after)
  VALUES (p_user, p_delta, 'admin_adjust', 'admin:' || gen_random_uuid()::text, left(p_actor, 100), bal) RETURNING entry_id INTO entry;
  INSERT INTO operator_audit(actor, action, target_type, target_id, reason, detail)
  VALUES (p_actor, 'coin_adjustment', 'user', p_user::text, p_reason, jsonb_build_object('delta', p_delta, 'balanceAfter', bal, 'ledgerEntry', entry));
  RETURN bal;
END
$$;
REVOKE ALL ON FUNCTION coin_admin_adjust(uuid, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION coin_ledger_append_only() FROM PUBLIC;

-- The account purge (store.purgeContent) removes everything billing keeps about a member: coins, ledger, purchases and subscriptions
-- (hashed store ids only), ad sessions and detail unlocks. The stores keep their own receipts; a live subscription is cancelled by the member in the
-- store (the deletion screens say so). Returns the number of rows removed.
CREATE FUNCTION purge_member_billing(p_user uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer := 0; c integer;
BEGIN
  PERFORM set_config('hiyall.purging_member', p_user::text, true);
  DELETE FROM coin_ledger WHERE user_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM coin_balances WHERE user_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM purchases WHERE user_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM subscriptions WHERE user_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM ad_reward_sessions WHERE user_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  DELETE FROM profile_detail_unlocks WHERE viewer_id = p_user OR target_id = p_user; GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  RETURN n;
END
$$;
