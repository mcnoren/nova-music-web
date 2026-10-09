-- Private, per-account metadata. No audio, provider credentials, or access tokens.
create table if not exists public.nova_music_libraries (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 1 check (revision > 0),
  document jsonb not null,
  updated_at timestamptz not null default now(),
  constraint nova_music_library_size check (octet_length(document::text) <= 10000000)
);
alter table public.nova_music_libraries enable row level security;
revoke all on public.nova_music_libraries from anon, authenticated;
grant select on public.nova_music_libraries to authenticated;
drop policy if exists "Read own Nova Music library" on public.nova_music_libraries;
create policy "Read own Nova Music library" on public.nova_music_libraries
  for select to authenticated using ((select auth.uid()) = user_id);

create or replace function public.save_nova_music_library(expected_revision bigint, library_document jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  account_id uuid := auth.uid();
  current_revision bigint;
  entry record;
begin
  if account_id is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if expected_revision < 0 or expected_revision is null then raise exception 'Invalid revision'; end if;
  if library_document is null or library_document->>'version' is distinct from '1'
    or jsonb_typeof(library_document->'records') is distinct from 'object'
    or octet_length(library_document::text) > 10000000 then raise exception 'Invalid library document'; end if;
  if (select count(*) from jsonb_object_keys(library_document->'records')) > 30000 then raise exception 'Library record limit exceeded'; end if;
  for entry in select key, value from jsonb_each(library_document->'records') loop
    if entry.key !~ '^[A-Za-z]+:[A-Za-z0-9_.:-]{1,240}$'
      or jsonb_typeof(entry.value) is distinct from 'object'
      or jsonb_typeof(entry.value->'clock') is distinct from 'number'
      or (entry.value->>'clock') !~ '^[0-9]+$'
      or (entry.value->>'clock')::numeric < 1
      or (entry.value->>'clock')::numeric > 9007199254740991
      or coalesce(entry.value->>'actor','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(entry.value->'deleted') is distinct from 'boolean'
      or (entry.value->>'deleted' = 'false' and not entry.value ? 'value')
    then raise exception 'Invalid library record'; end if;
  end loop;
  -- A transaction-level lock also serializes the first insert for this account.
  perform pg_advisory_xact_lock(hashtextextended(account_id::text, 7269));
  select revision into current_revision from public.nova_music_libraries where user_id = account_id for update;
  if coalesce(current_revision,0) <> expected_revision then
    return jsonb_build_object('conflict',true,'revision',coalesce(current_revision,0));
  end if;
  insert into public.nova_music_libraries(user_id, revision, document, updated_at)
    values(account_id,1,library_document,now())
    on conflict(user_id) do update set revision = public.nova_music_libraries.revision + 1, document = excluded.document, updated_at = now()
    returning revision into current_revision;
  return jsonb_build_object('conflict',false,'revision',current_revision);
end;
$$;
revoke all on function public.save_nova_music_library(bigint,jsonb) from public, anon;
grant execute on function public.save_nova_music_library(bigint,jsonb) to authenticated;
