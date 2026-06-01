-- Helper used only by the local smoke-test harness (NOT a migration).
-- Provides minimal stubs for Supabase's `auth` schema so 0001..0003 apply
-- against a bare Postgres instance in CI / local Docker.
--
-- Do NOT load this in production: Supabase already provides auth.users and
-- auth.uid().

create extension if not exists pgcrypto;
create schema if not exists auth;

create table if not exists auth.users (
    id    uuid primary key default gen_random_uuid(),
    email text
);

create or replace function auth.uid() returns uuid
language sql stable as $$ select null::uuid $$;
