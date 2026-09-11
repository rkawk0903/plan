-- 우리 결혼 플래너: 2인 공동 프로젝트용 Supabase schema
-- Supabase SQL Editor에서 전체 실행하세요.
-- 이 스키마는 Auth + RLS + Realtime을 사용합니다.

create extension if not exists pgcrypto;

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null default '우리 결혼 플래너',
  invite_code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (project_id, user_id)
);

create table if not exists public.project_state (
  project_id uuid primary key references public.projects(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create index if not exists project_members_user_idx on public.project_members(user_id);
create index if not exists project_state_updated_idx on public.project_state(updated_at desc);

alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.project_state enable row level security;

create or replace function public.is_project_member(p_project_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.project_members pm where pm.project_id=p_project_id and pm.user_id=auth.uid());
$$;
revoke all on function public.is_project_member(uuid) from public;
grant execute on function public.is_project_member(uuid) to authenticated;

drop policy if exists "members can read projects" on public.projects;
create policy "members can read projects" on public.projects for select to authenticated using (public.is_project_member(id));

drop policy if exists "users can read own memberships" on public.project_members;
create policy "users can read own memberships" on public.project_members for select to authenticated using (user_id=auth.uid());

drop policy if exists "members can read project state" on public.project_state;
create policy "members can read project state" on public.project_state for select to authenticated using (public.is_project_member(project_id));

drop policy if exists "members can insert project state" on public.project_state;
create policy "members can insert project state" on public.project_state for insert to authenticated with check (public.is_project_member(project_id) and updated_by=auth.uid());

drop policy if exists "members can update project state" on public.project_state;
create policy "members can update project state" on public.project_state for update to authenticated using (public.is_project_member(project_id)) with check (public.is_project_member(project_id) and updated_by=auth.uid());

-- Data API least-privilege grants. RLS remains the actual authorization boundary.
grant select on public.projects to authenticated;
grant select on public.project_members to authenticated;
grant select, insert, update, delete on public.project_state to authenticated;

create or replace function public.create_wedding_project(p_name text, p_invite_code text)
returns table(project_id uuid, invite_code text)
language plpgsql security definer set search_path = public as $$
declare v_project_id uuid; v_user uuid := auth.uid(); v_code text := upper(trim(p_invite_code));
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  if length(v_code) <> 8 then raise exception '초대 코드는 8자리여야 합니다.'; end if;
  if not v_code ~ '^[A-Z0-9]+$' then raise exception '초대 코드 형식이 올바르지 않습니다.'; end if;
  insert into public.projects(name, invite_code, owner_id)
  values(coalesce(nullif(trim(p_name),''),'우리 결혼 플래너'), v_code, v_user)
  returning id into v_project_id;
  insert into public.project_members(project_id,user_id,role) values(v_project_id,v_user,'owner');
  insert into public.project_state(project_id,state,updated_by) values(v_project_id,'{}'::jsonb,v_user);
  return query select v_project_id,v_code;
end;$$;
revoke all on function public.create_wedding_project(text,text) from public;
grant execute on function public.create_wedding_project(text,text) to authenticated;

create or replace function public.join_wedding_project(p_invite_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_project_id uuid; v_user uuid := auth.uid(); v_count integer; v_role text;
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  select id into v_project_id from public.projects where invite_code=upper(trim(p_invite_code)) limit 1;
  if v_project_id is null then raise exception '공유 프로젝트를 찾을 수 없습니다.'; end if;
  select role into v_role from public.project_members where project_id=v_project_id and user_id=v_user;
  if v_role is not null then return v_project_id; end if;
  select count(*) into v_count from public.project_members where project_id=v_project_id;
  if v_count >= 2 then raise exception '이 공동 프로젝트는 두 명이 이미 참여하고 있습니다.'; end if;
  insert into public.project_members(project_id,user_id,role) values(v_project_id,v_user,'member');
  return v_project_id;
end;$$;
revoke all on function public.join_wedding_project(text) from public;
grant execute on function public.join_wedding_project(text) to authenticated;

create or replace function public.find_wedding_project(p_invite_code text)
returns table(project_id uuid) language sql security definer set search_path=public as $$
  select p.id from public.projects p where p.invite_code=upper(trim(p_invite_code)) limit 1;
$$;
revoke all on function public.find_wedding_project(text) from public;
grant execute on function public.find_wedding_project(text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='project_state') then
    alter publication supabase_realtime add table public.project_state;
  end if;
end$$;

alter table public.project_state replica identity full;
