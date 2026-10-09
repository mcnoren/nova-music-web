-- Run only in a disposable local database. Simulates Supabase's authenticated roles.
create role anon;
create role authenticated;
create schema auth;
create table auth.users(id uuid primary key);
insert into auth.users values ('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth,public to anon,authenticated;
\ir ../supabase/migrations/202610090001_nova_music_sync.sql
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
select public.save_nova_music_library(0,'{"version":1,"records":{"liked:abcdefghijk":{"clock":1,"actor":"00000000-0000-4000-8000-000000000001","deleted":false,"value":{"id":"abcdefghijk","order":0}}}}');
do $$begin
 if (select count(*) from public.nova_music_libraries) <> 1 then raise exception 'Owner cannot read own row'; end if;
 if not (public.save_nova_music_library(0,'{"version":1,"records":{}}')->>'conflict')::boolean then raise exception 'Stale write was not rejected'; end if;
 if (select revision from public.nova_music_libraries) <> 1 then raise exception 'Stale write changed revision'; end if;
 begin
  update public.nova_music_libraries set document = '{"version":1,"records":{}}';
  raise exception 'Direct updates were allowed';
 exception when insufficient_privilege then null;
 end;
end$$;
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000002';
do $$begin
 if (select count(*) from public.nova_music_libraries) <> 0 then raise exception 'Another account can read the first account'; end if;
end$$;
select public.save_nova_music_library(0,'{"version":1,"records":{},"user_id":"00000000-0000-4000-8000-000000000001"}');
do $$begin
 if (select count(*) from public.nova_music_libraries) <> 1 then raise exception 'Second account cannot read its row'; end if;
 if (select user_id from public.nova_music_libraries) <> auth.uid() then raise exception 'Caller could spoof ownership'; end if;
 begin
  perform public.save_nova_music_library(1,'{"version":1,"records":{"invalid-key":{"clock":1,"actor":"x","deleted":true}}}');
  raise exception 'Malformed document was allowed';
 exception when raise_exception then
  if sqlerrm = 'Malformed document was allowed' then raise; end if;
 end;
end$$;
reset role;
set role anon;
do $$begin
 begin
  perform public.save_nova_music_library(0,'{"version":1,"records":{}}');
  raise exception 'Anonymous write was allowed';
 exception when insufficient_privilege then null;
 end;
 begin
  perform count(*) from public.nova_music_libraries;
  raise exception 'Anonymous read was allowed';
 exception when insufficient_privilege then null;
 end;
end$$;
reset role;
do $$begin
 if (select count(*) from public.nova_music_libraries) <> 2 then raise exception 'Account rows were overwritten'; end if;
end$$;
select 'PASS: own-account reads, anonymous denial, account isolation, protected writes, ownership and revisions' as access_tests;
