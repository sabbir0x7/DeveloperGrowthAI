-- DevGrowth AI — schema smoke test
--
-- Run this file standalone against any database that has had migrations
-- 0001_init_schema.sql, 0002_rls_policies.sql, and 0003_handle_new_user.sql
-- applied:
--
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/0001_schema_smoke.sql
--
-- The script verifies, by querying the system catalogs only:
--   1. The five public tables exist
--      (users, user_settings, analyses, skills, roadmaps).
--   2. Every column required by the design.md ER diagram is present on each
--      table, with the data type the diagram specifies.
--   3. Row-Level Security is enabled on every one of those tables.
--   4. Each table has at least one owner-only policy of each command
--      (SELECT, INSERT, UPDATE, DELETE), read from pg_policies.
--   5. The handle_new_user() function and the on_auth_user_created trigger
--      exist (sanity check on migration 0003).
--
-- Validates Requirements 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7.
--
-- Each check uses `RAISE EXCEPTION` on failure (which, combined with
-- ON_ERROR_STOP=1, halts psql with a non-zero exit code) and emits a
-- `RAISE NOTICE 'OK: ...'` on success so the run is observable in CI logs.

\set ON_ERROR_STOP on

begin;

-- -------------------------------------------------------------------------
-- 1. Table existence (Requirement 8.1).
-- -------------------------------------------------------------------------
do $$
declare
    expected_tables constant text[] := array[
        'users', 'user_settings', 'analyses', 'skills', 'roadmaps'
    ];
    t text;
    found boolean;
begin
    foreach t in array expected_tables loop
        select exists (
            select 1
            from information_schema.tables
            where table_schema = 'public'
              and table_type = 'BASE TABLE'
              and table_name = t
        ) into found;

        if not found then
            raise exception
                'schema smoke: missing table public.% (Requirement 8.1)', t;
        end if;
    end loop;

    raise notice 'OK: all 5 expected tables exist in schema public';
end;
$$;

-- -------------------------------------------------------------------------
-- 2. Column presence and data types per ER diagram
--    (Requirements 8.1, 8.2, 8.3, 8.4, 8.5).
--
-- information_schema.columns reports `data_type` using SQL-standard names:
--   uuid                       -> 'uuid'
--   text                       -> 'text'
--   bytea                      -> 'bytea'
--   jsonb                      -> 'jsonb'
--   numeric                    -> 'numeric'
--   timestamp with time zone   -> 'timestamp with time zone'
-- -------------------------------------------------------------------------
do $$
declare
    -- Triples of (table_name, column_name, expected information_schema data_type).
    -- Mirrors the ER diagram in design.md exactly.
    expected_columns constant text[][] := array[
        -- users (Requirement 8.1; profile fields read by 2.x / 3.x)
        ['users', 'id',           'uuid'],
        ['users', 'email',        'text'],
        ['users', 'full_name',    'text'],
        ['users', 'github_url',   'text'],
        ['users', 'linkedin_url', 'text'],
        ['users', 'goal',         'text'],
        ['users', 'created_at',   'timestamp with time zone'],

        -- user_settings (Requirement 8.2)
        ['user_settings', 'user_id',              'uuid'],
        ['user_settings', 'encrypted_ai_key',     'bytea'],
        ['user_settings', 'ai_provider_base_url', 'text'],
        ['user_settings', 'created_at',           'timestamp with time zone'],
        ['user_settings', 'updated_at',           'timestamp with time zone'],

        -- analyses (Requirement 8.3)
        ['analyses', 'id',           'uuid'],
        ['analyses', 'user_id',      'uuid'],
        ['analyses', 'goal',         'text'],
        ['analyses', 'github_url',   'text'],
        ['analyses', 'linkedin_url', 'text'],
        ['analyses', 'result_json',  'jsonb'],
        ['analyses', 'created_at',   'timestamp with time zone'],

        -- skills (Requirement 8.4)
        ['skills', 'id',               'uuid'],
        ['skills', 'user_id',          'uuid'],
        ['skills', 'name',             'text'],
        ['skills', 'gap_level',        'text'],
        ['skills', 'source',           'text'],
        ['skills', 'confidence_score', 'numeric'],
        ['skills', 'updated_at',       'timestamp with time zone'],

        -- roadmaps (Requirement 8.5)
        ['roadmaps', 'id',                  'uuid'],
        ['roadmaps', 'user_id',             'uuid'],
        ['roadmaps', 'title',               'text'],
        ['roadmaps', 'description',         'text'],
        ['roadmaps', 'priority',            'text'],
        ['roadmaps', 'target_role',         'text'],
        ['roadmaps', 'progress_percentage', 'numeric'],
        ['roadmaps', 'updated_at',          'timestamp with time zone']
    ];
    i int;
    tbl text;
    col text;
    expected_type text;
    actual_type text;
    checked_count int := 0;
begin
    for i in 1 .. array_length(expected_columns, 1) loop
        tbl           := expected_columns[i][1];
        col           := expected_columns[i][2];
        expected_type := expected_columns[i][3];

        select c.data_type
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name   = tbl
          and c.column_name  = col
        into actual_type;

        if actual_type is null then
            raise exception
                'schema smoke: missing column public.%.% (Requirement 8.x)',
                tbl, col;
        end if;

        if actual_type <> expected_type then
            raise exception
                'schema smoke: column public.%.% has type % but expected % (Requirement 8.x)',
                tbl, col, actual_type, expected_type;
        end if;

        checked_count := checked_count + 1;
    end loop;

    raise notice
        'OK: all % expected columns are present with the correct types',
        checked_count;
end;
$$;

-- -------------------------------------------------------------------------
-- 3. Row-Level Security is enabled on every table (Requirement 8.6).
-- pg_class.relrowsecurity is the authoritative flag.
-- -------------------------------------------------------------------------
do $$
declare
    expected_tables constant text[] := array[
        'users', 'user_settings', 'analyses', 'skills', 'roadmaps'
    ];
    t text;
    rls_on boolean;
begin
    foreach t in array expected_tables loop
        select c.relrowsecurity
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = t
        into rls_on;

        if rls_on is null then
            raise exception
                'schema smoke: table public.% not found while checking RLS (Requirement 8.6)', t;
        end if;

        if not rls_on then
            raise exception
                'schema smoke: RLS is NOT enabled on public.% (Requirement 8.6)', t;
        end if;
    end loop;

    raise notice 'OK: RLS is enabled on all 5 tables';
end;
$$;

-- -------------------------------------------------------------------------
-- 4. Each table has at least one policy for each of SELECT, INSERT, UPDATE,
--    and DELETE (Requirement 8.7).
--
-- The pg_policies view exposes a per-policy `cmd` column whose values are
-- 'SELECT', 'INSERT', 'UPDATE', 'DELETE', or 'ALL'. An 'ALL' policy is
-- accepted because it covers every command.
-- -------------------------------------------------------------------------
do $$
declare
    expected_tables constant text[] := array[
        'users', 'user_settings', 'analyses', 'skills', 'roadmaps'
    ];
    expected_cmds constant text[] := array[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE'
    ];
    t text;
    expected_cmd text;
    has_policy boolean;
    total_policies int;
begin
    foreach t in array expected_tables loop
        foreach expected_cmd in array expected_cmds loop
            select exists (
                select 1
                from pg_policies p
                where p.schemaname = 'public'
                  and p.tablename  = t
                  and (p.cmd = expected_cmd or p.cmd = 'ALL')
            ) into has_policy;

            if not has_policy then
                raise exception
                    'schema smoke: table public.% is missing a % policy (Requirement 8.7)',
                    t, expected_cmd;
            end if;
        end loop;
    end loop;

    -- Sanity floor: 5 tables × 4 commands = 20 owner-only policies minimum.
    select count(*)
    from pg_policies
    where schemaname = 'public'
      and tablename = any(expected_tables)
    into total_policies;

    if total_policies < 20 then
        raise exception
            'schema smoke: expected at least 20 RLS policies across the 5 tables, found % (Requirement 8.7)',
            total_policies;
    end if;

    raise notice
        'OK: every table has SELECT/INSERT/UPDATE/DELETE policies (% policies total)',
        total_policies;
end;
$$;

-- -------------------------------------------------------------------------
-- 5. handle_new_user() function and on_auth_user_created trigger exist
--    (sanity check on migration 0003 — supports Requirement 2.5 indirectly
--    by ensuring the wiring needed to mirror auth.users into public.users
--    is present).
-- -------------------------------------------------------------------------
do $$
declare
    fn_exists boolean;
    trg_exists boolean;
begin
    select exists (
        select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'handle_new_user'
    ) into fn_exists;

    if not fn_exists then
        raise exception
            'schema smoke: function public.handle_new_user() is missing (migration 0003)';
    end if;

    select exists (
        select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'auth'
          and c.relname = 'users'
          and t.tgname  = 'on_auth_user_created'
          and not t.tgisinternal
    ) into trg_exists;

    if not trg_exists then
        raise exception
            'schema smoke: trigger on_auth_user_created on auth.users is missing (migration 0003)';
    end if;

    raise notice 'OK: handle_new_user() function and on_auth_user_created trigger are installed';
end;
$$;

-- All assertions passed.
do $$
begin
    raise notice 'OK: schema smoke — all checks passed';
end;
$$;

commit;
