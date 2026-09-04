-- LIVE DATABASE: apply supabase/licensing-account-cutover.sql instead of this
-- greenfield file when stupidmirror_licensing already exists.
--
-- Reference copy of the StupidMirror licensing schema deployed to Supabase.
-- The schema is intentionally private. Only service_role may execute the
-- narrow RPC wrappers used by the Edge Functions.
--
-- Account-bound cutover (auth.uid principal):
-- 1. Do not brick existing Keychain receipts; honor them without login during grace.
-- 2. One-way in-app claim from old receipt -> auth.uid().
-- 3. After claim, the account is the license principal.
-- 4. No double seat (one active entitlement per user; one active seat per code).
-- 5. Unused codes redeem to account after login; already-activated codes only via claim.
-- 6. Grace period keeps v0.2.x validate/activate working until grace_ends_at.
-- 7. Admin reset revokes any linked account entitlement so it cannot mint a second seat.
--
-- Deploy notes (human): enable Google + GitHub in Supabase Auth; never commit secrets;
-- apply this SQL; redeploy stupidmirror-license and stupidmirror-license-admin.

create schema if not exists stupidmirror_licensing;

revoke all on schema stupidmirror_licensing
  from public, anon, authenticated, service_role;

create table if not exists stupidmirror_licensing.admin_tokens (
  token_hash text primary key
    check (token_hash ~ '^[0-9a-f]{64}$'),
  label text not null
    check (char_length(label) between 1 and 120),
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  last_used_at timestamptz
);

create table if not exists stupidmirror_licensing.license_batches (
  id uuid primary key,
  payload_digest text not null
    check (payload_digest ~ '^[0-9a-f]{64}$'),
  code_count integer not null
    check (code_count between 1 and 5000),
  created_by_token_hash text not null
    references stupidmirror_licensing.admin_tokens(token_hash),
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists license_batches_created_by_token
  on stupidmirror_licensing.license_batches(created_by_token_hash);

create table if not exists stupidmirror_licensing.license_codes (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null
    references stupidmirror_licensing.license_batches(id),
  code_hash text not null unique
    check (code_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'available'
    check (status in ('available', 'activated', 'revoked', 'redeemed')),
  created_at timestamptz not null default clock_timestamp(),
  activated_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text
);

create index if not exists license_codes_batch
  on stupidmirror_licensing.license_codes(batch_id);

-- Legacy install-bound activations (Keychain receipt). Kept for grace + claim.
create table if not exists stupidmirror_licensing.activations (
  id uuid primary key default gen_random_uuid(),
  license_code_id uuid not null
    references stupidmirror_licensing.license_codes(id),
  installation_hash text not null
    check (installation_hash ~ '^[0-9a-f]{64}$'),
  receipt uuid not null default gen_random_uuid() unique,
  app_version text,
  activated_at timestamptz not null default clock_timestamp(),
  last_validated_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  revoke_reason text,
  claimed_by_user_id uuid,
  claimed_at timestamptz
);

create unique index if not exists one_active_activation_per_license_code
  on stupidmirror_licensing.activations(license_code_id)
  where revoked_at is null;

create unique index if not exists one_active_license_per_installation
  on stupidmirror_licensing.activations(installation_hash)
  where revoked_at is null;

-- Account-bound entitlements. auth.uid() is the license principal after cutover.
create table if not exists stupidmirror_licensing.account_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  license_code_id uuid not null
    references stupidmirror_licensing.license_codes(id),
  source text not null
    check (source in ('redeem', 'claim')),
  claimed_from_activation_id uuid
    references stupidmirror_licensing.activations(id),
  created_at timestamptz not null default clock_timestamp(),
  last_validated_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  revoke_reason text
);

create unique index if not exists one_active_entitlement_per_user
  on stupidmirror_licensing.account_entitlements(user_id)
  where revoked_at is null;

create unique index if not exists one_active_entitlement_per_license_code
  on stupidmirror_licensing.account_entitlements(license_code_id)
  where revoked_at is null;

create table if not exists stupidmirror_licensing.activation_rate_limits (
  subject_hash text not null
    check (subject_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  attempts integer not null
    check (attempts > 0),
  primary key (subject_hash, window_started_at)
);

create index if not exists activation_rate_limits_window
  on stupidmirror_licensing.activation_rate_limits(window_started_at);

-- Cutover configuration (single row).
create table if not exists stupidmirror_licensing.cutover_config (
  id boolean primary key default true check (id),
  grace_ends_at timestamptz not null,
  updated_at timestamptz not null default clock_timestamp()
);

insert into stupidmirror_licensing.cutover_config(id, grace_ends_at)
values (true, timestamptz '2026-12-31 15:59:59+00')
on conflict (id) do nothing;

alter table stupidmirror_licensing.admin_tokens enable row level security;
alter table stupidmirror_licensing.license_batches enable row level security;
alter table stupidmirror_licensing.license_codes enable row level security;
alter table stupidmirror_licensing.activations enable row level security;
alter table stupidmirror_licensing.account_entitlements enable row level security;
alter table stupidmirror_licensing.activation_rate_limits enable row level security;
alter table stupidmirror_licensing.cutover_config enable row level security;

revoke all on all tables in schema stupidmirror_licensing
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema stupidmirror_licensing
  from public, anon, authenticated, service_role;

create or replace function stupidmirror_licensing.grace_active(p_now timestamptz default clock_timestamp())
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
      from stupidmirror_licensing.cutover_config c
     where c.id
       and p_now < c.grace_ends_at
  );
$$;

create or replace function stupidmirror_licensing.is_legacy_app_version(p_app_version text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_app_version, '') ~ '^0\.2(\.|$)';
$$;

create or replace function stupidmirror_licensing.consume_rate_limit(
  p_scope text,
  p_subject_hash text,
  p_subject_limit integer,
  p_global_limit integer
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_window timestamptz;
  v_subject_key text;
  v_global_key text;
  v_subject_attempts integer;
  v_global_attempts integer;
begin
  if p_scope is null
     or char_length(p_scope) not between 1 and 32
     or p_subject_hash is null
     or p_subject_hash !~ '^[0-9a-f]{64}$'
     or p_subject_limit < 1
     or p_global_limit < p_subject_limit then
    return false;
  end if;

  v_window := date_bin(interval '10 minutes', v_now, timestamptz '2000-01-01 00:00:00+00');
  v_subject_key := encode(
    extensions.digest(convert_to('subject:' || p_scope || ':' || p_subject_hash, 'UTF8'), 'sha256'),
    'hex'
  );
  v_global_key := encode(
    extensions.digest(convert_to('global:' || p_scope, 'UTF8'), 'sha256'),
    'hex'
  );

  insert into stupidmirror_licensing.activation_rate_limits(
    subject_hash,
    window_started_at,
    attempts
  ) values (v_subject_key, v_window, 1)
  on conflict (subject_hash, window_started_at)
  do update set attempts = case
    when stupidmirror_licensing.activation_rate_limits.attempts >= p_subject_limit + 1
      then stupidmirror_licensing.activation_rate_limits.attempts
    else stupidmirror_licensing.activation_rate_limits.attempts + 1
  end
  returning attempts into v_subject_attempts;

  if v_subject_attempts > p_subject_limit then
    return false;
  end if;

  insert into stupidmirror_licensing.activation_rate_limits(
    subject_hash,
    window_started_at,
    attempts
  ) values (v_global_key, v_window, 1)
  on conflict (subject_hash, window_started_at)
  do update set attempts = case
    when stupidmirror_licensing.activation_rate_limits.attempts >= p_global_limit + 1
      then stupidmirror_licensing.activation_rate_limits.attempts
    else stupidmirror_licensing.activation_rate_limits.attempts + 1
  end
  returning attempts into v_global_attempts;

  if random() < 0.01 then
    delete from stupidmirror_licensing.activation_rate_limits
     where ctid in (
       select ctid
         from stupidmirror_licensing.activation_rate_limits
        where window_started_at < v_now - interval '2 days'
        order by window_started_at
        limit 200
     );
  end if;

  return v_global_attempts <= p_global_limit;
end;
$$;

revoke all on function stupidmirror_licensing.consume_rate_limit(text, text, integer, integer)
  from public, anon, authenticated, service_role;

-- Legacy install activate (grace / v0.2.x only after cutover policy).
create or replace function public.stupidmirror_activate_license(
  p_code_hash text,
  p_installation_hash text,
  p_rate_subject_hash text,
  p_app_version text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_code stupidmirror_licensing.license_codes%rowtype;
  v_activation stupidmirror_licensing.activations%rowtype;
  v_activation_code_hash text;
  v_activation_code_status text;
  v_grace boolean := stupidmirror_licensing.grace_active(v_now);
  v_legacy_app boolean := stupidmirror_licensing.is_legacy_app_version(p_app_version);
begin
  if p_code_hash is null
     or p_installation_hash is null
     or p_rate_subject_hash is null
     or p_code_hash !~ '^[0-9a-f]{64}$'
     or p_installation_hash !~ '^[0-9a-f]{64}$'
     or p_rate_subject_hash !~ '^[0-9a-f]{64}$'
     or char_length(coalesce(p_app_version, '')) > 64 then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The activation request is malformed.',
      'server_time', v_now
    );
  end if;

  -- After grace, only v0.2.x clients may still use install-bound activate.
  if not v_grace and not v_legacy_app then
    return jsonb_build_object(
      'ok', false,
      'code', 'account_required',
      'message', 'Sign in and redeem this code to your account.',
      'server_time', v_now,
      'grace_active', false
    );
  end if;

  if not stupidmirror_licensing.consume_rate_limit(
    'activate',
    p_rate_subject_hash,
    20,
    2000
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'rate_limited',
      'message', 'Too many activation attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_installation_hash, 0));

  select a.*
    into v_activation
    from stupidmirror_licensing.activations a
   where a.installation_hash = p_installation_hash
     and a.revoked_at is null
   for update;

  if found then
    select c.code_hash, c.status
      into v_activation_code_hash, v_activation_code_status
      from stupidmirror_licensing.license_codes c
     where c.id = v_activation.license_code_id;

    if v_activation_code_hash is distinct from p_code_hash
       or v_activation_code_status is distinct from 'activated' then
      return jsonb_build_object(
        'ok', false,
        'code', 'invalid_or_unavailable',
        'message', 'The activation code is invalid or has already been used.',
        'server_time', v_now
      );
    end if;

    if v_activation.claimed_by_user_id is not null then
      return jsonb_build_object(
        'ok', false,
        'code', 'already_claimed',
        'message', 'This installation license was claimed to an account. Sign in to that account.',
        'server_time', v_now
      );
    end if;

    update stupidmirror_licensing.activations
       set last_validated_at = v_now,
           app_version = nullif(p_app_version, '')
     where id = v_activation.id;

    return jsonb_build_object(
      'ok', true,
      'valid', true,
      'receipt', v_activation.receipt,
      'principal', 'installation',
      'grace_active', v_grace,
      'server_time', v_now
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.code_hash = p_code_hash
   for update;

  if not found or v_code.status <> 'available' then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_or_unavailable',
      'message', 'The activation code is invalid or has already been used.',
      'server_time', v_now
    );
  end if;

  -- Code already bound to an account entitlement cannot be install-activated.
  if exists (
    select 1
      from stupidmirror_licensing.account_entitlements e
     where e.license_code_id = v_code.id
       and e.revoked_at is null
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_or_unavailable',
      'message', 'The activation code is invalid or has already been used.',
      'server_time', v_now
    );
  end if;

  insert into stupidmirror_licensing.activations(
    license_code_id,
    installation_hash,
    app_version,
    activated_at,
    last_validated_at
  ) values (
    v_code.id,
    p_installation_hash,
    nullif(p_app_version, ''),
    v_now,
    v_now
  )
  returning * into v_activation;

  update stupidmirror_licensing.license_codes
     set status = 'activated',
         activated_at = v_now
   where id = v_code.id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation.receipt,
    'principal', 'installation',
    'grace_active', v_grace,
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_validate_license(
  p_receipt uuid,
  p_installation_hash text,
  p_rate_subject_hash text,
  p_app_version text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_activation_id uuid;
  v_activation_receipt uuid;
  v_activation_revoked_at timestamptz;
  v_claimed_by uuid;
  v_code_status text;
  v_grace boolean := stupidmirror_licensing.grace_active(v_now);
  v_legacy_app boolean := stupidmirror_licensing.is_legacy_app_version(p_app_version);
begin
  if p_installation_hash is null
     or p_installation_hash !~ '^[0-9a-f]{64}$'
     or p_rate_subject_hash is null
     or p_rate_subject_hash !~ '^[0-9a-f]{64}$'
     or char_length(coalesce(p_app_version, '')) > 64 then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The validation request is malformed.',
      'server_time', v_now
    );
  end if;

  if not stupidmirror_licensing.consume_rate_limit(
    'validate',
    p_rate_subject_hash,
    120,
    10000
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'rate_limited',
      'message', 'Too many validation attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  select a.id, a.receipt, a.revoked_at, a.claimed_by_user_id, c.status
    into v_activation_id, v_activation_receipt, v_activation_revoked_at, v_claimed_by, v_code_status
    from stupidmirror_licensing.activations a
    join stupidmirror_licensing.license_codes c
      on c.id = a.license_code_id
   where a.receipt = p_receipt
     and a.installation_hash = p_installation_hash
   for update of a;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_receipt',
      'message', 'This activation receipt is not valid for this installation.',
      'server_time', v_now
    );
  end if;

  if v_activation_revoked_at is not null or v_code_status = 'revoked' then
    return jsonb_build_object(
      'ok', false,
      'code', 'license_revoked',
      'message', 'This license has been revoked.',
      'server_time', v_now
    );
  end if;

  if v_claimed_by is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_claimed',
      'message', 'This installation license was claimed to an account. Sign in to use paid features.',
      'server_time', v_now,
      'grace_active', v_grace
    );
  end if;

  -- After grace, Keychain receipt alone must not keep granting paid features
  -- forever for non-legacy clients. Claim to an account instead.
  if not v_grace and not v_legacy_app then
    return jsonb_build_object(
      'ok', false,
      'code', 'claim_required',
      'message', 'Sign in and claim this license to your account to keep paid features.',
      'receipt', v_activation_receipt,
      'grace_active', false,
      'server_time', v_now
    );
  end if;

  update stupidmirror_licensing.activations
     set last_validated_at = v_now,
         app_version = nullif(p_app_version, '')
   where id = v_activation_id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation_receipt,
    'principal', 'installation',
    'grace_active', v_grace,
    'needs_claim', not v_grace,
    'server_time', v_now
  );
end;
$$;

-- Redeem an unused SM- code onto the signed-in account.
create or replace function public.stupidmirror_redeem_license_to_account(
  p_user_id uuid,
  p_code_hash text,
  p_rate_subject_hash text,
  p_app_version text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_code stupidmirror_licensing.license_codes%rowtype;
  v_entitlement stupidmirror_licensing.account_entitlements%rowtype;
begin
  if p_user_id is null
     or p_code_hash is null
     or p_code_hash !~ '^[0-9a-f]{64}$'
     or p_rate_subject_hash is null
     or p_rate_subject_hash !~ '^[0-9a-f]{64}$'
     or char_length(coalesce(p_app_version, '')) > 64 then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The redeem request is malformed.',
      'server_time', v_now
    );
  end if;

  if not stupidmirror_licensing.consume_rate_limit(
    'redeem',
    p_rate_subject_hash,
    20,
    2000
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'rate_limited',
      'message', 'Too many redeem attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(p_code_hash, 1));

  select e.*
    into v_entitlement
    from stupidmirror_licensing.account_entitlements e
   where e.user_id = p_user_id
     and e.revoked_at is null
   for update;

  if found then
    return jsonb_build_object(
      'ok', false,
      'code', 'double_entitlement',
      'message', 'This account already has an active license seat.',
      'server_time', v_now
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.code_hash = p_code_hash
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_or_unavailable',
      'message', 'The activation code is invalid or has already been used.',
      'server_time', v_now
    );
  end if;

  if v_code.status = 'activated' then
    return jsonb_build_object(
      'ok', false,
      'code', 'claim_required',
      'message', 'This code was already activated on a Mac. Sign in there and claim the existing receipt to your account.',
      'server_time', v_now
    );
  end if;

  if v_code.status <> 'available' then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_or_unavailable',
      'message', 'The activation code is invalid or has already been used.',
      'server_time', v_now
    );
  end if;

  insert into stupidmirror_licensing.account_entitlements(
    user_id,
    license_code_id,
    source,
    created_at,
    last_validated_at
  ) values (
    p_user_id,
    v_code.id,
    'redeem',
    v_now,
    v_now
  )
  returning * into v_entitlement;

  update stupidmirror_licensing.license_codes
     set status = 'redeemed',
         activated_at = v_now
   where id = v_code.id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'principal', 'account',
    'entitlement_id', v_entitlement.id,
    'source', 'redeem',
    'server_time', v_now
  );
end;
$$;

-- One-way claim: bind an existing install receipt to auth.uid().
create or replace function public.stupidmirror_claim_license_from_receipt(
  p_user_id uuid,
  p_receipt uuid,
  p_installation_hash text,
  p_rate_subject_hash text,
  p_app_version text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_activation stupidmirror_licensing.activations%rowtype;
  v_code stupidmirror_licensing.license_codes%rowtype;
  v_entitlement stupidmirror_licensing.account_entitlements%rowtype;
begin
  if p_user_id is null
     or p_receipt is null
     or p_installation_hash is null
     or p_installation_hash !~ '^[0-9a-f]{64}$'
     or p_rate_subject_hash is null
     or p_rate_subject_hash !~ '^[0-9a-f]{64}$'
     or char_length(coalesce(p_app_version, '')) > 64 then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The claim request is malformed.',
      'server_time', v_now
    );
  end if;

  if not stupidmirror_licensing.consume_rate_limit(
    'claim',
    p_rate_subject_hash,
    20,
    2000
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'rate_limited',
      'message', 'Too many claim attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(p_installation_hash, 0));

  select e.*
    into v_entitlement
    from stupidmirror_licensing.account_entitlements e
   where e.user_id = p_user_id
     and e.revoked_at is null
   for update;

  if found then
    -- Idempotent: same receipt already claimed to this account.
    if v_entitlement.claimed_from_activation_id is not null then
      select a.*
        into v_activation
        from stupidmirror_licensing.activations a
       where a.id = v_entitlement.claimed_from_activation_id;
      if found
         and v_activation.receipt = p_receipt
         and v_activation.installation_hash = p_installation_hash then
        return jsonb_build_object(
          'ok', true,
          'valid', true,
          'principal', 'account',
          'entitlement_id', v_entitlement.id,
          'source', 'claim',
          'idempotent', true,
          'server_time', v_now
        );
      end if;
    end if;

    return jsonb_build_object(
      'ok', false,
      'code', 'double_entitlement',
      'message', 'This account already has an active license seat.',
      'server_time', v_now
    );
  end if;

  select a.*
    into v_activation
    from stupidmirror_licensing.activations a
   where a.receipt = p_receipt
     and a.installation_hash = p_installation_hash
   for update;

  if not found or v_activation.revoked_at is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_receipt',
      'message', 'This activation receipt is not valid for this installation.',
      'server_time', v_now
    );
  end if;

  if v_activation.claimed_by_user_id is not null then
    if v_activation.claimed_by_user_id = p_user_id then
      select e.*
        into v_entitlement
        from stupidmirror_licensing.account_entitlements e
       where e.user_id = p_user_id
         and e.revoked_at is null;
      return jsonb_build_object(
        'ok', true,
        'valid', true,
        'principal', 'account',
        'entitlement_id', v_entitlement.id,
        'source', 'claim',
        'idempotent', true,
        'server_time', v_now
      );
    end if;
    return jsonb_build_object(
      'ok', false,
      'code', 'already_claimed',
      'message', 'This installation license was already claimed to another account.',
      'server_time', v_now
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.id = v_activation.license_code_id
   for update;

  if not found or v_code.status = 'revoked' then
    return jsonb_build_object(
      'ok', false,
      'code', 'license_revoked',
      'message', 'This license has been revoked.',
      'server_time', v_now
    );
  end if;

  if exists (
    select 1
      from stupidmirror_licensing.account_entitlements e
     where e.license_code_id = v_code.id
       and e.revoked_at is null
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'double_entitlement',
      'message', 'This license code already has an active account seat.',
      'server_time', v_now
    );
  end if;

  insert into stupidmirror_licensing.account_entitlements(
    user_id,
    license_code_id,
    source,
    claimed_from_activation_id,
    created_at,
    last_validated_at
  ) values (
    p_user_id,
    v_code.id,
    'claim',
    v_activation.id,
    v_now,
    v_now
  )
  returning * into v_entitlement;

  update stupidmirror_licensing.activations
     set claimed_by_user_id = p_user_id,
         claimed_at = v_now,
         last_validated_at = v_now,
         app_version = nullif(p_app_version, '')
   where id = v_activation.id;

  -- Account becomes the principal; install receipt no longer independently seats.
  update stupidmirror_licensing.license_codes
     set status = 'redeemed'
   where id = v_code.id
     and status = 'activated';

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'principal', 'account',
    'entitlement_id', v_entitlement.id,
    'source', 'claim',
    'idempotent', false,
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_validate_account_license(
  p_user_id uuid,
  p_rate_subject_hash text,
  p_app_version text default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_entitlement stupidmirror_licensing.account_entitlements%rowtype;
  v_code_status text;
  v_grace boolean := stupidmirror_licensing.grace_active(v_now);
begin
  if p_user_id is null
     or p_rate_subject_hash is null
     or p_rate_subject_hash !~ '^[0-9a-f]{64}$'
     or char_length(coalesce(p_app_version, '')) > 64 then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The account validation request is malformed.',
      'server_time', v_now
    );
  end if;

  if not stupidmirror_licensing.consume_rate_limit(
    'validate_account',
    p_rate_subject_hash,
    120,
    10000
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'rate_limited',
      'message', 'Too many validation attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  select e.*
    into v_entitlement
    from stupidmirror_licensing.account_entitlements e
   where e.user_id = p_user_id
     and e.revoked_at is null
   for update;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'valid', false,
      'principal', 'account',
      'grace_active', v_grace,
      'server_time', v_now
    );
  end if;

  select c.status
    into v_code_status
    from stupidmirror_licensing.license_codes c
   where c.id = v_entitlement.license_code_id;

  if v_code_status = 'revoked' then
    update stupidmirror_licensing.account_entitlements
       set revoked_at = v_now,
           revoke_reason = 'code_revoked'
     where id = v_entitlement.id;
    return jsonb_build_object(
      'ok', false,
      'code', 'license_revoked',
      'message', 'This license has been revoked.',
      'server_time', v_now
    );
  end if;

  update stupidmirror_licensing.account_entitlements
     set last_validated_at = v_now
   where id = v_entitlement.id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'principal', 'account',
    'entitlement_id', v_entitlement.id,
    'source', v_entitlement.source,
    'grace_active', v_grace,
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_admin_create_license_batch(
  p_admin_token_hash text,
  p_batch_id uuid,
  p_payload_digest text,
  p_code_hashes text[]
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_count integer := coalesce(array_length(p_code_hashes, 1), 0);
  v_computed_digest text;
  v_existing stupidmirror_licensing.license_batches%rowtype;
begin
  if p_admin_token_hash is null
     or p_admin_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'code', 'unauthorized');
  end if;

  perform 1
    from stupidmirror_licensing.admin_tokens t
   where t.token_hash = p_admin_token_hash
     and t.is_active
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'unauthorized');
  end if;

  if p_payload_digest is null
     or p_payload_digest !~ '^[0-9a-f]{64}$'
     or v_count < 1
     or v_count > 5000
     or exists (
       select 1
         from unnest(p_code_hashes) as code_hash
        where code_hash !~ '^[0-9a-f]{64}$'
     )
     or (select count(distinct code_hash) from unnest(p_code_hashes) as code_hash) <> v_count then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The activation-code batch is malformed.'
    );
  end if;

  select encode(
           extensions.digest(
             convert_to(string_agg(code_hash, E'\n' order by code_hash) || E'\n', 'UTF8'),
             'sha256'
           ),
           'hex'
         )
    into v_computed_digest
    from unnest(p_code_hashes) as code_hash;

  if v_computed_digest <> p_payload_digest then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The activation-code manifest digest does not match its contents.'
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_batch_id::text, 0));

  select b.*
    into v_existing
    from stupidmirror_licensing.license_batches b
   where b.id = p_batch_id
   for update;

  if found then
    if v_existing.payload_digest = p_payload_digest
       and v_existing.code_count = v_count then
      return jsonb_build_object(
        'ok', true,
        'batch_id', v_existing.id,
        'count', v_existing.code_count,
        'payload_digest', v_existing.payload_digest,
        'idempotent', true
      );
    end if;

    return jsonb_build_object(
      'ok', false,
      'code', 'batch_conflict',
      'message', 'The batch identifier was already used with different data.'
    );
  end if;

  begin
    insert into stupidmirror_licensing.license_batches(
      id,
      payload_digest,
      code_count,
      created_by_token_hash,
      created_at
    ) values (
      p_batch_id,
      p_payload_digest,
      v_count,
      p_admin_token_hash,
      v_now
    );

    insert into stupidmirror_licensing.license_codes(batch_id, code_hash)
    select p_batch_id, code_hash
      from unnest(p_code_hashes) as code_hash;
  exception
    when unique_violation then
      return jsonb_build_object(
        'ok', false,
        'code', 'duplicate_code',
        'message', 'One or more activation codes already exist.'
      );
  end;

  update stupidmirror_licensing.admin_tokens
     set last_used_at = v_now
   where token_hash = p_admin_token_hash;

  return jsonb_build_object(
    'ok', true,
    'batch_id', p_batch_id,
    'count', v_count,
    'payload_digest', p_payload_digest,
    'idempotent', false
  );
end;
$$;

-- Admin reset: return code to available AND revoke any account entitlement so
-- reset cannot mint a second seat.
create or replace function public.stupidmirror_admin_reset_license_code(
  p_admin_token_hash text,
  p_code_hash text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_code stupidmirror_licensing.license_codes%rowtype;
  v_activation stupidmirror_licensing.activations%rowtype;
  v_reset boolean := false;
  v_entitlement_revoked boolean := false;
begin
  if p_admin_token_hash is null
     or p_admin_token_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'code', 'unauthorized');
  end if;

  perform 1
    from stupidmirror_licensing.admin_tokens t
   where t.token_hash = p_admin_token_hash
     and t.is_active
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'unauthorized');
  end if;

  if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object(
      'ok', false,
      'code', 'malformed_request',
      'message', 'The activation-code reset request is malformed.'
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.code_hash = p_code_hash
   for update;

  if not found or v_code.status = 'revoked' then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_or_unavailable',
      'message', 'The activation code does not exist or cannot be reset.'
    );
  end if;

  select a.*
    into v_activation
    from stupidmirror_licensing.activations a
   where a.license_code_id = v_code.id
     and a.revoked_at is null
   for update;

  if found then
    update stupidmirror_licensing.activations
       set revoked_at = v_now,
           revoke_reason = 'superseded'
     where id = v_activation.id;
    v_reset := true;
  end if;

  update stupidmirror_licensing.account_entitlements
     set revoked_at = v_now,
         revoke_reason = 'admin_reset'
   where license_code_id = v_code.id
     and revoked_at is null;
  if found then
    v_entitlement_revoked := true;
    v_reset := true;
  end if;

  update stupidmirror_licensing.license_codes
     set status = 'available',
         activated_at = null,
         revoked_at = null,
         revoke_reason = null
   where id = v_code.id;

  update stupidmirror_licensing.admin_tokens
     set last_used_at = v_now
   where token_hash = p_admin_token_hash;

  return jsonb_build_object(
    'ok', true,
    'code_status', 'available',
    'reset', v_reset,
    'entitlement_revoked', v_entitlement_revoked
  );
end;
$$;

revoke all on function public.stupidmirror_activate_license(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_validate_license(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_redeem_license_to_account(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_claim_license_from_receipt(uuid, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_validate_account_license(uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_admin_create_license_batch(text, uuid, text, text[])
  from public, anon, authenticated;
revoke all on function public.stupidmirror_admin_reset_license_code(text, text)
  from public, anon, authenticated;

grant execute on function public.stupidmirror_activate_license(text, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_validate_license(uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_redeem_license_to_account(uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_claim_license_from_receipt(uuid, uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_validate_account_license(uuid, text, text)
  to service_role;
grant execute on function public.stupidmirror_admin_create_license_batch(text, uuid, text, text[])
  to service_role;
grant execute on function public.stupidmirror_admin_reset_license_code(text, text)
  to service_role;

comment on schema stupidmirror_licensing is
  'Private StupidMirror activation data. Never expose this schema through the Data API. Account entitlements bind to auth.uid(); install receipts are legacy/grace/claim only.';
