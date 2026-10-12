-- =====================================================================
--  Planner Nikah — skema database Supabase
--  Cara pakai: Supabase Dashboard → SQL Editor → New query →
--  tempel seluruh isi file ini → Run. Aman dijalankan ulang.
-- =====================================================================

-- ---------- Tabel ----------------------------------------------------

-- Satu baris = satu planner pernikahan (milik satu pasangan)
create table if not exists public.weddings (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,   -- nama, tanggal, berkas, dll.
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Anggota planner: pemilik + maksimal 1 pasangan.
-- Satu akun hanya bisa berada di satu planner (unique user_id).
create table if not exists public.wedding_members (
  wedding_id  uuid not null references public.weddings(id) on delete cascade,
  user_id     uuid not null unique references auth.users(id) on delete cascade,
  role        text not null check (role in ('owner','partner')),
  pihak       text not null check (pihak in ('A','B')),
  email       text,
  joined_at   timestamptz not null default now(),
  primary key (wedding_id, user_id)
);
create unique index if not exists wedding_one_owner   on public.wedding_members (wedding_id) where role = 'owner';
create unique index if not exists wedding_one_partner on public.wedding_members (wedding_id) where role = 'partner';

-- Kode undangan pasangan
create table if not exists public.invites (
  code        text primary key,
  wedding_id  uuid not null references public.weddings(id) on delete cascade,
  created_by  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_by     uuid references auth.users(id) on delete set null,
  used_at     timestamptz
);

-- Semua catatan: vendor, kantong, transaksi, tugas, tamu, seserahan
create table if not exists public.items (
  id          uuid primary key default gen_random_uuid(),
  wedding_id  uuid not null references public.weddings(id) on delete cascade,
  kind        text not null check (kind in ('vendors','kantong','transaksi','tugas','tamu','seserahan')),
  data        jsonb not null default '{}'::jsonb,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists items_wedding_kind on public.items (wedding_id, kind);

-- ---------- Fungsi bantu --------------------------------------------

-- Apakah akun yang sedang login anggota planner ini?
create or replace function public.is_member(p_wedding uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.wedding_members
                 where wedding_id = p_wedding and user_id = auth.uid());
$$;

-- Gabung JSON secara mendalam; nilai null menghapus kunci
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare k text; v jsonb; r jsonb;
begin
  if b is null then return a; end if;
  if a is null or jsonb_typeof(a) <> 'object' or jsonb_typeof(b) <> 'object' then return b; end if;
  r := a;
  for k, v in select * from jsonb_each(b) loop
    if v = 'null'::jsonb then
      r := r - k;
    else
      r := jsonb_set(r, array[k], public.jsonb_deep_merge(r -> k, v));
    end if;
  end loop;
  return r;
end $$;

-- Kode acak 8 huruf, tanpa huruf yang mirip (0/O, 1/I/L)
create or replace function public.new_invite_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  b bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  out text := '';
  i int;
begin
  for i in 0..7 loop
    out := out || substr(alphabet, 1 + (get_byte(b, i * 4) % length(alphabet)), 1);
  end loop;
  return out;
end $$;

-- ---------- Row Level Security --------------------------------------

alter table public.weddings        enable row level security;
alter table public.wedding_members enable row level security;
alter table public.invites         enable row level security;
alter table public.items           enable row level security;

drop policy if exists "anggota lihat planner" on public.weddings;
create policy "anggota lihat planner" on public.weddings
  for select to authenticated using (public.is_member(id));

drop policy if exists "anggota lihat anggota" on public.wedding_members;
create policy "anggota lihat anggota" on public.wedding_members
  for select to authenticated using (public.is_member(wedding_id));

drop policy if exists "anggota lihat undangan" on public.invites;
create policy "anggota lihat undangan" on public.invites
  for select to authenticated using (public.is_member(wedding_id));

drop policy if exists "anggota lihat catatan" on public.items;
create policy "anggota lihat catatan" on public.items
  for select to authenticated using (public.is_member(wedding_id));

drop policy if exists "anggota tambah catatan" on public.items;
create policy "anggota tambah catatan" on public.items
  for insert to authenticated with check (public.is_member(wedding_id) and created_by = auth.uid());

drop policy if exists "anggota ubah catatan" on public.items;
create policy "anggota ubah catatan" on public.items
  for update to authenticated using (public.is_member(wedding_id)) with check (public.is_member(wedding_id));

drop policy if exists "anggota hapus catatan" on public.items;
create policy "anggota hapus catatan" on public.items
  for delete to authenticated using (public.is_member(wedding_id));

-- Hak akses tabel: yang belum login tidak bisa apa-apa.
-- Planner, anggota, dan undangan hanya bisa diubah lewat fungsi di bawah.
revoke all on public.weddings, public.wedding_members, public.invites, public.items from anon, authenticated;
grant select on public.weddings, public.wedding_members, public.invites to authenticated;
grant select, insert, delete on public.items to authenticated;
grant update (data, updated_at) on public.items to authenticated;

-- ---------- Fungsi yang dipanggil aplikasi --------------------------

-- Buat planner baru; pemanggil jadi pemilik
create or replace function public.create_wedding(p_data jsonb, p_pihak text)
returns uuid language plpgsql security definer set search_path = public as $$
declare w uuid; uid uuid := auth.uid();
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_pihak not in ('A','B') then raise exception 'BAD_PIHAK'; end if;
  if exists (select 1 from wedding_members where user_id = uid) then raise exception 'ALREADY_MEMBER'; end if;
  insert into weddings (owner_id, data) values (uid, coalesce(p_data, '{}'::jsonb)) returning id into w;
  insert into wedding_members (wedding_id, user_id, role, pihak, email)
    values (w, uid, 'owner', p_pihak, (select email from auth.users where id = uid));
  return w;
end $$;

-- Ubah sebagian data planner (nama, tanggal, berkas, dll.)
create or replace function public.patch_wedding(p_wedding uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_member(p_wedding) then raise exception 'NOT_MEMBER'; end if;
  update weddings set data = public.jsonb_deep_merge(data, p_patch), updated_at = now()
    where id = p_wedding returning data into r;
  return r;
end $$;

-- Ubah sebagian isi satu catatan (tunduk pada RLS)
create or replace function public.patch_item(p_id uuid, p_patch jsonb)
returns public.items language plpgsql security invoker set search_path = public as $$
declare r public.items;
begin
  update items set data = public.jsonb_deep_merge(data, p_patch), updated_at = now()
    where id = p_id returning * into r;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  return r;
end $$;

-- Pemilik membuat kode undangan untuk 1 pasangan.
-- Kode lama yang belum dipakai dibuat kedaluwarsa (riwayat tetap tersimpan).
create or replace function public.create_invite()
returns table (code text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare w uuid; uid uuid := auth.uid(); c text;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select m.wedding_id into w from wedding_members m where m.user_id = uid and m.role = 'owner';
  if w is null then raise exception 'NOT_OWNER'; end if;
  if exists (select 1 from wedding_members m where m.wedding_id = w and m.role = 'partner') then
    raise exception 'WEDDING_FULL';
  end if;
  update invites i set expires_at = now() where i.wedding_id = w and i.used_by is null and i.expires_at > now();
  loop
    c := public.new_invite_code();
    exit when not exists (select 1 from invites i where i.code = c);
  end loop;
  insert into invites (code, wedding_id, created_by) values (c, w, uid);
  return query select i.code, i.expires_at from invites i where i.code = c;
end $$;

-- Pasangan memakai kode undangan
create or replace function public.accept_invite(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype; uid uuid := auth.uid(); owner_pihak text;
begin
  if uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if exists (select 1 from wedding_members where user_id = uid) then raise exception 'ALREADY_MEMBER'; end if;
  select * into inv from invites where code = upper(trim(p_code)) for update;
  if inv.code is null then raise exception 'INVITE_NOT_FOUND'; end if;
  if inv.used_by is not null then raise exception 'INVITE_USED'; end if;
  if inv.expires_at < now() then raise exception 'INVITE_EXPIRED'; end if;
  perform 1 from weddings where id = inv.wedding_id for update;
  if exists (select 1 from wedding_members where wedding_id = inv.wedding_id and role = 'partner') then
    raise exception 'WEDDING_FULL';
  end if;
  select pihak into owner_pihak from wedding_members where wedding_id = inv.wedding_id and role = 'owner';
  insert into wedding_members (wedding_id, user_id, role, pihak, email)
    values (inv.wedding_id, uid, 'partner', case when owner_pihak = 'A' then 'B' else 'A' end,
            (select email from auth.users where id = uid));
  update invites set used_by = uid, used_at = now() where code = inv.code;
  return inv.wedding_id;
end $$;

-- Pemilik melepas pasangan, supaya bisa mengundang akun lain
create or replace function public.remove_partner()
returns void language plpgsql security definer set search_path = public as $$
declare w uuid;
begin
  select wedding_id into w from wedding_members where user_id = auth.uid() and role = 'owner';
  if w is null then raise exception 'NOT_OWNER'; end if;
  delete from wedding_members where wedding_id = w and role = 'partner';
  update invites set expires_at = now() where wedding_id = w and used_by is null and expires_at > now();
end $$;

-- Pasangan keluar dari planner
create or replace function public.leave_wedding()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from wedding_members where user_id = auth.uid() and role = 'partner') then
    raise exception 'NOT_PARTNER';
  end if;
  delete from wedding_members where user_id = auth.uid() and role = 'partner';
end $$;

revoke execute on function public.create_wedding(jsonb, text), public.patch_wedding(uuid, jsonb),
  public.patch_item(uuid, jsonb), public.create_invite(), public.accept_invite(text),
  public.remove_partner(), public.leave_wedding(), public.is_member(uuid),
  public.new_invite_code(), public.jsonb_deep_merge(jsonb, jsonb) from public, anon;
grant execute on function public.create_wedding(jsonb, text), public.patch_wedding(uuid, jsonb),
  public.patch_item(uuid, jsonb), public.create_invite(), public.accept_invite(text),
  public.remove_partner(), public.leave_wedding(), public.is_member(uuid),
  public.jsonb_deep_merge(jsonb, jsonb) to authenticated;

-- ---------- Sinkron langsung (realtime) -----------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.items;           exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.weddings;        exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.wedding_members; exception when duplicate_object then null; end;
  end if;
end $$;
