-- Migration: 0003_handle_new_user.sql
-- Requirement: 2.5 — "WHEN a new user authenticates for the first time,
--   THE Profile_Service SHALL create a corresponding row in the `users` table
--   linked to the Supabase auth user ID."
--
-- Intent:
--   Supabase manages identity rows in the `auth.users` table. The application
--   keeps its own profile row in `public.users` keyed by the same UUID. To
--   guarantee the public row exists the moment a user first authenticates
--   (so subsequent profile reads/writes never race with row creation), we
--   install an `AFTER INSERT` trigger on `auth.users` that mirrors the new
--   user's id and email into `public.users`.
--
--   The function is declared `SECURITY DEFINER` so it can write to
--   `public.users` regardless of the inserting role's privileges (the
--   `auth` schema is owned by Supabase's `supabase_auth_admin`). The
--   `ON CONFLICT (id) DO NOTHING` clause keeps the trigger idempotent in
--   case the public row already exists (e.g. created by an out-of-band
--   migration or a replay).

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.users (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end; $$;

-- Drop-then-create keeps the migration idempotent: re-running this file (e.g.
-- on a fresh `supabase db reset` or repeated `db push`) will not fail because
-- the trigger already exists on auth.users.
drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
