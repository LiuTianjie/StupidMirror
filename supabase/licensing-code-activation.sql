-- v0.3.3 follow-up for either existing licensing schema. Apply manually before
-- the former account-migration grace period ends. No seats or codes are changed.
-- Existing code hashes, receipts, revocation, rate limits and account ownership
-- checks remain in their original RPCs; only the mandatory account deadline ends.
begin;

create or replace function stupidmirror_licensing.grace_active(p_now timestamptz default clock_timestamp())
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select true;
$$;

create or replace function stupidmirror_licensing.installation_claim_deadline()
returns timestamptz
language sql
immutable
set search_path = pg_catalog
as $$
  select null::timestamptz;
$$;

revoke all on function stupidmirror_licensing.grace_active(timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function stupidmirror_licensing.installation_claim_deadline()
  from public, anon, authenticated, service_role;

commit;
