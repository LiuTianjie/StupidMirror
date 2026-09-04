-- Account-bound licensing cutover for an already-deployed stupidmirror_licensing schema.
-- Apply this in the Supabase SQL editor (service role). It is additive: existing
-- Keychain receipts and Mac-bound activations remain valid. Do not run the
-- greenfield licensing-schema.sql against a live database that already has data.
--
-- Target project: iTool Supabase mkbeusztkzffnzjdwmqk (same auth.uid as Pro).
-- After applying: deploy supabase/functions/stupidmirror-license.
-- Do not enable extra Auth providers if iTool Google/GitHub/email already work;
-- only add redirect URL stupidmirror://auth-callback.

create or replace function stupidmirror_licensing.installation_claim_deadline()
returns timestamptz
language sql
immutable
set search_path = pg_catalog
as $$
  -- New clients honor a Mac-bound Keychain receipt until this instant, then
  -- require a one-way claim onto auth.uid(). v0.2.x validate/activate ignore it.
  select timestamptz '2026-12-02 00:00:00+00';
$$;

revoke all on function stupidmirror_licensing.installation_claim_deadline()
  from public, anon, authenticated, service_role;

alter table stupidmirror_licensing.license_codes
  add column if not exists bind_mode text;

update stupidmirror_licensing.license_codes
   set bind_mode = 'legacy_or_account'
 where bind_mode is null;

alter table stupidmirror_licensing.license_codes
  alter column bind_mode set default 'legacy_or_account';

alter table stupidmirror_licensing.license_codes
  alter column bind_mode set not null;

alter table stupidmirror_licensing.license_codes
  drop constraint if exists license_codes_bind_mode_check;

alter table stupidmirror_licensing.license_codes
  add constraint license_codes_bind_mode_check
  check (bind_mode in ('legacy_or_account', 'account_only'));

alter table stupidmirror_licensing.activations
  add column if not exists user_id uuid;

alter table stupidmirror_licensing.activations
  add column if not exists principal text;

update stupidmirror_licensing.activations
   set principal = 'installation'
 where principal is null;

alter table stupidmirror_licensing.activations
  alter column principal set default 'installation';

alter table stupidmirror_licensing.activations
  alter column principal set not null;

alter table stupidmirror_licensing.activations
  drop constraint if exists activations_principal_check;

alter table stupidmirror_licensing.activations
  add constraint activations_principal_check
  check (principal in ('installation', 'account'));

alter table stupidmirror_licensing.activations
  drop constraint if exists activations_account_has_user;

alter table stupidmirror_licensing.activations
  add constraint activations_account_has_user
  check (principal <> 'account' or user_id is not null);

alter table stupidmirror_licensing.activations
  add column if not exists claimed_at timestamptz;

drop index if exists stupidmirror_licensing.one_active_license_per_installation;

create unique index if not exists one_active_installation_bound_license
  on stupidmirror_licensing.activations(installation_hash)
  where revoked_at is null and principal = 'installation';

create unique index if not exists one_active_account_license_per_user
  on stupidmirror_licensing.activations(user_id)
  where revoked_at is null and user_id is not null;

-- Keep one_active_activation_per_license_code: one live seat per code.

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
     and a.principal = 'installation'
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

    update stupidmirror_licensing.activations
       set last_validated_at = v_now,
           app_version = nullif(p_app_version, '')
     where id = v_activation.id;

    return jsonb_build_object(
      'ok', true,
      'valid', true,
      'receipt', v_activation.receipt,
      'principal', 'installation',
      'needs_claim', true,
      'claim_by', stupidmirror_licensing.installation_claim_deadline(),
      'server_time', v_now
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.code_hash = p_code_hash
   for update;

  -- Unused codes may still Mac-bind for v0.2.x. Codes already activated, or
  -- codes marked account_only after redeem/claim/reset of an account seat,
  -- must not be treated as a fresh Mac-bound seat.
  if not found
     or v_code.status <> 'available'
     or v_code.bind_mode = 'account_only' then
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
    principal,
    activated_at,
    last_validated_at
  ) values (
    v_code.id,
    p_installation_hash,
    nullif(p_app_version, ''),
    'installation',
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
    'needs_claim', true,
    'claim_by', stupidmirror_licensing.installation_claim_deadline(),
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
  v_principal text;
  v_user_id uuid;
  v_code_status text;
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

  select a.id, a.receipt, a.revoked_at, a.principal, a.user_id, c.status
    into v_activation_id, v_activation_receipt, v_activation_revoked_at,
         v_principal, v_user_id, v_code_status
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

  -- After claim the account is the principal. Same-Mac receipt validation still
  -- works so the original installation is not bricked, but needs_claim is false.
  update stupidmirror_licensing.activations
     set last_validated_at = v_now,
         app_version = nullif(p_app_version, '')
   where id = v_activation_id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation_receipt,
    'principal', v_principal,
    'needs_claim', (v_principal = 'installation'),
    'claim_by', stupidmirror_licensing.installation_claim_deadline(),
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_redeem_license(
  p_code_hash text,
  p_user_id uuid,
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
  v_existing stupidmirror_licensing.activations%rowtype;
begin
  if p_code_hash is null
     or p_user_id is null
     or p_installation_hash is null
     or p_rate_subject_hash is null
     or p_code_hash !~ '^[0-9a-f]{64}$'
     or p_installation_hash !~ '^[0-9a-f]{64}$'
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
      'message', 'Too many redemption attempts. Try again later.',
      'server_time', v_now
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(p_code_hash, 1));

  select a.*
    into v_existing
    from stupidmirror_licensing.activations a
   where a.user_id = p_user_id
     and a.revoked_at is null
   for update;

  if found then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_licensed',
      'message', 'This account already has an active StupidMirror license.',
      'server_time', v_now
    );
  end if;

  select c.*
    into v_code
    from stupidmirror_licensing.license_codes c
   where c.code_hash = p_code_hash
   for update;

  -- Only unused available codes redeem onto an account. An already-activated
  -- Mac-bound code is not unused; claim-from-receipt is the only conversion.
  if not found or v_code.status <> 'available' then
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
    user_id,
    principal,
    claimed_at,
    app_version,
    activated_at,
    last_validated_at
  ) values (
    v_code.id,
    p_installation_hash,
    p_user_id,
    'account',
    v_now,
    nullif(p_app_version, ''),
    v_now,
    v_now
  )
  returning * into v_activation;

  update stupidmirror_licensing.license_codes
     set status = 'activated',
         activated_at = v_now,
         bind_mode = 'account_only'
   where id = v_code.id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation.receipt,
    'principal', 'account',
    'needs_claim', false,
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_claim_license(
  p_receipt uuid,
  p_user_id uuid,
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
  v_existing stupidmirror_licensing.activations%rowtype;
  v_code_status text;
  v_bind_mode text;
begin
  if p_receipt is null
     or p_user_id is null
     or p_installation_hash is null
     or p_rate_subject_hash is null
     or p_installation_hash !~ '^[0-9a-f]{64}$'
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

  select a.*
    into v_activation
    from stupidmirror_licensing.activations a
   where a.receipt = p_receipt
     and a.installation_hash = p_installation_hash
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_receipt',
      'message', 'This activation receipt is not valid for this installation.',
      'server_time', v_now
    );
  end if;

  select c.status, c.bind_mode
    into v_code_status, v_bind_mode
    from stupidmirror_licensing.license_codes c
   where c.id = v_activation.license_code_id
   for update;

  if v_activation.revoked_at is not null or v_code_status = 'revoked' then
    return jsonb_build_object(
      'ok', false,
      'code', 'license_revoked',
      'message', 'This license has been revoked.',
      'server_time', v_now
    );
  end if;

  -- Idempotent claim onto the same account. Possession of the receipt is the
  -- proof; do not create a second seat.
  if v_activation.principal = 'account' then
    if v_activation.user_id is not distinct from p_user_id then
      update stupidmirror_licensing.activations
         set last_validated_at = v_now,
             app_version = nullif(p_app_version, ''),
             claimed_at = coalesce(v_activation.claimed_at, v_now)
       where id = v_activation.id;
      return jsonb_build_object(
        'ok', true,
        'valid', true,
        'receipt', v_activation.receipt,
        'principal', 'account',
        'needs_claim', false,
        'server_time', v_now
      );
    end if;
    return jsonb_build_object(
      'ok', false,
      'code', 'already_claimed',
      'message', 'This activation is already bound to another account.',
      'server_time', v_now
    );
  end if;

  select a.*
    into v_existing
    from stupidmirror_licensing.activations a
   where a.user_id = p_user_id
     and a.revoked_at is null
     and a.id <> v_activation.id
   for update;

  if found then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_licensed',
      'message', 'This account already has an active StupidMirror license.',
      'server_time', v_now
    );
  end if;

  update stupidmirror_licensing.activations
     set user_id = p_user_id,
         principal = 'account',
         claimed_at = v_now,
         last_validated_at = v_now,
         app_version = nullif(p_app_version, '')
   where id = v_activation.id
  returning * into v_activation;

  update stupidmirror_licensing.license_codes
     set bind_mode = 'account_only'
   where id = v_activation.license_code_id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation.receipt,
    'principal', 'account',
    'needs_claim', false,
    'server_time', v_now
  );
end;
$$;

create or replace function public.stupidmirror_validate_account_license(
  p_user_id uuid,
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
  v_code_status text;
begin
  if p_user_id is null
     or p_installation_hash is null
     or p_installation_hash !~ '^[0-9a-f]{64}$'
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
    'account_validate',
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

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  select a.*
    into v_activation
    from stupidmirror_licensing.activations a
   where a.user_id = p_user_id
     and a.revoked_at is null
     and a.principal = 'account'
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_receipt',
      'message', 'This account does not have an active StupidMirror license.',
      'server_time', v_now
    );
  end if;

  select c.status
    into v_code_status
    from stupidmirror_licensing.license_codes c
   where c.id = v_activation.license_code_id;

  if v_code_status = 'revoked' then
    return jsonb_build_object(
      'ok', false,
      'code', 'license_revoked',
      'message', 'This license has been revoked.',
      'server_time', v_now
    );
  end if;

  -- installation_hash is device metadata after claim/redeem, not a second seat.
  update stupidmirror_licensing.activations
     set last_validated_at = v_now,
         app_version = nullif(p_app_version, ''),
         installation_hash = p_installation_hash
   where id = v_activation.id
  returning * into v_activation;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation.receipt,
    'principal', 'account',
    'needs_claim', false,
    'server_time', v_now
  );
end;
$$;

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
  v_reset boolean := false;
  v_was_account boolean := false;
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

  -- Revoke every live seat for this code (Mac-bound and account-bound) so reset
  -- cannot leave an account licensed while minting a new Mac-bound seat.
  if exists (
    select 1
      from stupidmirror_licensing.activations a
     where a.license_code_id = v_code.id
       and a.revoked_at is null
       and a.principal = 'account'
  ) or v_code.bind_mode = 'account_only' then
    v_was_account := true;
  end if;

  update stupidmirror_licensing.activations
     set revoked_at = v_now,
         revoke_reason = 'admin_reset'
   where license_code_id = v_code.id
     and revoked_at is null;
  if found then
    v_reset := true;
  end if;

  update stupidmirror_licensing.license_codes
     set status = 'available',
         activated_at = null,
         revoked_at = null,
         revoke_reason = null,
         bind_mode = case
           when v_was_account then 'account_only'
           else bind_mode
         end
   where id = v_code.id;

  update stupidmirror_licensing.admin_tokens
     set last_used_at = v_now
   where token_hash = p_admin_token_hash;

  return jsonb_build_object(
    'ok', true,
    'code_status', 'available',
    'reset', v_reset,
    'redeem_principal', case when v_was_account then 'account' else 'legacy_or_account' end
  );
end;
$$;

revoke all on function public.stupidmirror_redeem_license(text, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_claim_license(uuid, uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_validate_account_license(uuid, text, text, text)
  from public, anon, authenticated;

grant execute on function public.stupidmirror_activate_license(text, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_validate_license(uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_redeem_license(text, uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_claim_license(uuid, uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_validate_account_license(uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_admin_reset_license_code(text, text)
  to service_role;
