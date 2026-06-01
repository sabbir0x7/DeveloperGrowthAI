-- DevGrowth AI — Row-Level Security policies
-- Enables RLS and installs owner-only select/insert/update/delete policies on
-- every user-owned table. The policy predicate is `auth.uid() = user_id` for
-- every table except `users`, where the owning column is `id` itself.
--
-- Validates Requirements 8.6, 8.7.

-- -------------------------------------------------------------------------
-- users — owner column is `id` (mirrors auth.users.id).
-- -------------------------------------------------------------------------
alter table public.users enable row level security;

drop policy if exists users_select on public.users;
create policy users_select on public.users
    for select
    using (auth.uid() = id);

drop policy if exists users_insert on public.users;
create policy users_insert on public.users
    for insert
    with check (auth.uid() = id);

drop policy if exists users_update on public.users;
create policy users_update on public.users
    for update
    using (auth.uid() = id)
    with check (auth.uid() = id);

drop policy if exists users_delete on public.users;
create policy users_delete on public.users
    for delete
    using (auth.uid() = id);

-- -------------------------------------------------------------------------
-- user_settings — owner column is `user_id`.
-- -------------------------------------------------------------------------
alter table public.user_settings enable row level security;

drop policy if exists user_settings_select on public.user_settings;
create policy user_settings_select on public.user_settings
    for select
    using (auth.uid() = user_id);

drop policy if exists user_settings_insert on public.user_settings;
create policy user_settings_insert on public.user_settings
    for insert
    with check (auth.uid() = user_id);

drop policy if exists user_settings_update on public.user_settings;
create policy user_settings_update on public.user_settings
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists user_settings_delete on public.user_settings;
create policy user_settings_delete on public.user_settings
    for delete
    using (auth.uid() = user_id);

-- -------------------------------------------------------------------------
-- analyses — owner column is `user_id`.
-- -------------------------------------------------------------------------
alter table public.analyses enable row level security;

drop policy if exists analyses_select on public.analyses;
create policy analyses_select on public.analyses
    for select
    using (auth.uid() = user_id);

drop policy if exists analyses_insert on public.analyses;
create policy analyses_insert on public.analyses
    for insert
    with check (auth.uid() = user_id);

drop policy if exists analyses_update on public.analyses;
create policy analyses_update on public.analyses
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists analyses_delete on public.analyses;
create policy analyses_delete on public.analyses
    for delete
    using (auth.uid() = user_id);

-- -------------------------------------------------------------------------
-- skills — owner column is `user_id`.
-- -------------------------------------------------------------------------
alter table public.skills enable row level security;

drop policy if exists skills_select on public.skills;
create policy skills_select on public.skills
    for select
    using (auth.uid() = user_id);

drop policy if exists skills_insert on public.skills;
create policy skills_insert on public.skills
    for insert
    with check (auth.uid() = user_id);

drop policy if exists skills_update on public.skills;
create policy skills_update on public.skills
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists skills_delete on public.skills;
create policy skills_delete on public.skills
    for delete
    using (auth.uid() = user_id);

-- -------------------------------------------------------------------------
-- roadmaps — owner column is `user_id`.
-- -------------------------------------------------------------------------
alter table public.roadmaps enable row level security;

drop policy if exists roadmaps_select on public.roadmaps;
create policy roadmaps_select on public.roadmaps
    for select
    using (auth.uid() = user_id);

drop policy if exists roadmaps_insert on public.roadmaps;
create policy roadmaps_insert on public.roadmaps
    for insert
    with check (auth.uid() = user_id);

drop policy if exists roadmaps_update on public.roadmaps;
create policy roadmaps_update on public.roadmaps
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists roadmaps_delete on public.roadmaps;
create policy roadmaps_delete on public.roadmaps
    for delete
    using (auth.uid() = user_id);
