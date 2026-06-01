-- DevGrowth AI — initial schema
-- Creates: users, user_settings, analyses, skills, roadmaps
-- RLS, policies, and the handle_new_user trigger live in subsequent migrations.

-- gen_random_uuid() lives in pgcrypto.
create extension if not exists pgcrypto;

-- -------------------------------------------------------------------------
-- users: mirrors auth.users; one row per Supabase auth user.
-- id is the Supabase auth.uid() so RLS can compare auth.uid() = id directly.
-- -------------------------------------------------------------------------
create table if not exists public.users (
    id           uuid primary key references auth.users (id) on delete cascade,
    email        text not null,
    full_name    text,
    github_url   text,
    linkedin_url text,
    goal         text,
    created_at   timestamptz not null default now(),
    constraint users_goal_length_chk check (goal is null or length(goal) <= 500)
);

-- -------------------------------------------------------------------------
-- user_settings: per-user AI provider config. One row per user.
-- encrypted_ai_key is Fernet ciphertext (bytea); base URL is plaintext.
-- -------------------------------------------------------------------------
create table if not exists public.user_settings (
    user_id              uuid primary key references public.users (id) on delete cascade,
    encrypted_ai_key     bytea,
    ai_provider_base_url text,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- analyses: append-only log of AI analysis runs. result_json holds the full
-- AnalysisEnvelope (github_analysis, linkedin_analysis, skill_gaps, suggestions).
-- -------------------------------------------------------------------------
create table if not exists public.analyses (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references public.users (id) on delete cascade,
    goal         text,
    github_url   text,
    linkedin_url text,
    result_json  jsonb not null,
    created_at   timestamptz not null default now()
);

-- "Latest analysis per user" lookup (GET /analysis/latest).
create index if not exists analyses_user_id_created_at_idx
    on public.analyses (user_id, created_at desc);

-- -------------------------------------------------------------------------
-- skills: upserted from each AnalysisEnvelope.skill_gaps. Unique per (user, name).
-- source must be one of github | linkedin | ai.
-- -------------------------------------------------------------------------
create table if not exists public.skills (
    id               uuid primary key default gen_random_uuid(),
    user_id          uuid not null references public.users (id) on delete cascade,
    name             text not null,
    gap_level        text,
    source           text,
    confidence_score numeric,
    updated_at       timestamptz not null default now(),
    constraint skills_user_name_uk unique (user_id, name),
    constraint skills_source_chk check (source is null or source in ('github', 'linkedin', 'ai'))
);

-- -------------------------------------------------------------------------
-- roadmaps: upserted from each AnalysisEnvelope.suggestions. Unique per (user, title).
-- -------------------------------------------------------------------------
create table if not exists public.roadmaps (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references public.users (id) on delete cascade,
    title               text not null,
    description         text,
    priority            text,
    target_role         text,
    progress_percentage numeric not null default 0,
    updated_at          timestamptz not null default now(),
    constraint roadmaps_user_title_uk unique (user_id, title)
);
