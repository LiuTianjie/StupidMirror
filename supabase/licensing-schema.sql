-- Reference copy of the StupidMirror licensing schema deployed to Supabase.
-- The schema is intentionally private. Only service_role may execute the
-- narrow RPC wrappers used by the two Edge Functions.

create schema stupidmirror_licensing;

revoke all on schema stupidmirror_licensing
  from public, anon, authenticated, service_role;

create table stupidmirror_licensing.admin_tokens (
  token_hash text primary key
    check (token_hash ~ '^[0-9a-f]{64}$'),
  label text not null
    check (char_length(label) between 1 and 120),
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  last_used_at timestamptz
);

create table stupidmirror_licensing.license_batches (
  id uuid primary key,
  payload_digest text not null
    check (payload_digest ~ '^[0-9a-f]{64}$'),
  code_count integer not null
    check (code_count between 1 and 5000),
  created_by_token_hash text not null
    references stupidmirror_licensing.admin_tokens(token_hash),
  created_at timestamptz not null default clock_timestamp()
);

create index license_batches_created_by_token
  on stupidmirror_licensing.license_batches(created_by_token_hash);

create table stupidmirror_licensing.license_codes (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null
    references stupidmirror_licensing.license_batches(id),
  code_hash text not null unique
    check (code_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'available'
    check (status in ('available', 'activated', 'revoked')),
  created_at timestamptz not null default clock_timestamp(),
  activated_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text
);

create index license_codes_batch
  on stupidmirror_licensing.license_codes(batch_id);

create table stupidmirror_licensing.activations (
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
  revoke_reason text
);

create unique index one_active_activation_per_license_code
  on stupidmirror_licensing.activations(license_code_id)
  where revoked_at is null;

create unique index one_active_license_per_installation
  on stupidmirror_licensing.activations(installation_hash)
  where revoked_at is null;

create table stupidmirror_licensing.activation_rate_limits (
  subject_hash text not null
    check (subject_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  attempts integer not null
    check (attempts > 0),
  primary key (subject_hash, window_started_at)
);

create index activation_rate_limits_window
  on stupidmirror_licensing.activation_rate_limits(window_started_at);

alter table stupidmirror_licensing.admin_tokens enable row level security;
alter table stupidmirror_licensing.license_batches enable row level security;
alter table stupidmirror_licensing.license_codes enable row level security;
alter table stupidmirror_licensing.activations enable row level security;
alter table stupidmirror_licensing.activation_rate_limits enable row level security;

revoke all on all tables in schema stupidmirror_licensing
  from public, anon, authenticated, service_role;
revoke all on all sequences in schema stupidmirror_licensing
  from public, anon, authenticated, service_role;

create function stupidmirror_licensing.consume_rate_limit(
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

  -- Requests already blocked by one subject must not be able to consume the
  -- project-wide allowance and deny service to unrelated installations.
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

  -- Keep request latency bounded: one percent of requests remove at most 200
  -- expired buckets. Never run an unbounded table-wide cleanup inline.
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

create function public.stupidmirror_activate_license(
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

  -- Serialize requests for one installation so concurrent requests cannot
  -- consume two activation codes before the partial unique index is visible.
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

    update stupidmirror_licensing.activations
       set last_validated_at = v_now,
           app_version = nullif(p_app_version, '')
     where id = v_activation.id;

    return jsonb_build_object(
      'ok', true,
      'valid', true,
      'receipt', v_activation.receipt,
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
    'server_time', v_now
  );
end;
$$;

create function public.stupidmirror_validate_license(
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

  select a.id, a.receipt, a.revoked_at, c.status
    into v_activation_id, v_activation_receipt, v_activation_revoked_at, v_code_status
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

  update stupidmirror_licensing.activations
     set last_validated_at = v_now,
         app_version = nullif(p_app_version, '')
   where id = v_activation_id;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'receipt', v_activation_receipt,
    'server_time', v_now
  );
end;
$$;

create function public.stupidmirror_admin_create_license_batch(
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

create function public.stupidmirror_admin_reset_license_code(
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
    'reset', v_reset
  );
end;
$$;

revoke all on function public.stupidmirror_activate_license(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_validate_license(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.stupidmirror_admin_create_license_batch(text, uuid, text, text[])
  from public, anon, authenticated;
revoke all on function public.stupidmirror_admin_reset_license_code(text, text)
  from public, anon, authenticated;

grant execute on function public.stupidmirror_activate_license(text, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_validate_license(uuid, text, text, text)
  to service_role;
grant execute on function public.stupidmirror_admin_create_license_batch(text, uuid, text, text[])
  to service_role;
grant execute on function public.stupidmirror_admin_reset_license_code(text, text)
  to service_role;

comment on schema stupidmirror_licensing is
  'Private StupidMirror activation data. Never expose this schema through the Data API.';
