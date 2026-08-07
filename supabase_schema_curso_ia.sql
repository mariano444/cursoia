-- =====================================================================
-- ACADEMIA IA 2026 — Esquema Supabase
-- Alumnos · Inscripciones · Progreso · Certificado final (auto-emitido y
-- bloqueado hasta completar el 100% del curso)
--
-- Cómo usarlo:
--   1. Supabase Dashboard → SQL Editor → pegar todo este archivo → Run.
--   2. Se puede correr una sola vez sobre un proyecto nuevo (usa
--      "create table if not exists" y "drop ... if exists" donde aplica
--      para que sea re-ejecutable sin romper nada).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. EXTENSIONES
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- 1. PERFILES (extiende auth.users)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text,
  email        text,
  avatar_url   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is 'Datos públicos del alumno, 1 a 1 con auth.users';

-- Crea automáticamente el perfil cuando alguien se registra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------------------------------------------------------------------
-- 2. CURSOS, MÓDULOS Y LECCIONES
-- ---------------------------------------------------------------------
create table if not exists public.courses (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,
  title         text not null,
  description   text,
  is_published  boolean not null default true,
  created_at    timestamptz not null default now()
);

create table if not exists public.modules (
  id            uuid primary key default gen_random_uuid(),
  course_id     uuid not null references public.courses(id) on delete cascade,
  order_index   int not null,
  title         text not null,
  slug          text not null,
  unique (course_id, order_index),
  unique (course_id, slug)
);

create table if not exists public.lessons (
  id            uuid primary key default gen_random_uuid(),
  module_id     uuid not null references public.modules(id) on delete cascade,
  order_index   int not null,
  title         text not null,
  page_key      text,
  video_url     text,
  duration_sec  int,
  is_preview    boolean not null default false,   -- visible sin inscripción
  unique (module_id, order_index)
);

create index if not exists idx_modules_course on public.modules(course_id);
create index if not exists idx_lessons_module on public.lessons(module_id);
alter table public.lessons add column if not exists page_key text;
create unique index if not exists idx_lessons_page_key_unique
  on public.lessons(page_key)
  where page_key is not null;

-- ---------------------------------------------------------------------
-- 3. INSCRIPCIONES (enrollments)
-- ---------------------------------------------------------------------
create table if not exists public.enrollments (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  course_id     uuid not null references public.courses(id) on delete cascade,
  enrolled_at   timestamptz not null default now(),
  status        text not null default 'active' check (status in ('active','cancelled')),
  unique (user_id, course_id)
);

create index if not exists idx_enrollments_user on public.enrollments(user_id);

-- ---------------------------------------------------------------------
-- 3.b PAGOS GALIOPAY
-- ---------------------------------------------------------------------
create table if not exists public.payment_orders (
  id                    uuid primary key default gen_random_uuid(),
  reference_id          text unique not null,
  user_id               uuid references auth.users(id) on delete set null,
  course_id             uuid references public.courses(id) on delete set null,
  payer_name            text not null,
  payer_email           text not null,
  payer_phone           text,
  amount                int not null default 4990,
  currency              text not null default 'ARS',
  status                text not null default 'pending'
                        check (status in ('pending','approved','refunded','failed')),
  galiopay_url          text,
  galiopay_payment_id   text,
  galiopay_raw          jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists idx_payment_orders_user on public.payment_orders(user_id);
create index if not exists idx_payment_orders_reference on public.payment_orders(reference_id);

create or replace function public.touch_payment_order()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_touch_payment_order on public.payment_orders;
create trigger trg_touch_payment_order
  before update on public.payment_orders
  for each row execute procedure public.touch_payment_order();

create or replace function public.activate_enrollment_from_payment(
  p_reference_id text,
  p_payment_id text,
  p_status text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.payment_orders%rowtype;
begin
  select * into v_order
  from public.payment_orders
  where reference_id = p_reference_id
  for update;

  if not found then
    raise exception 'payment order % not found', p_reference_id;
  end if;

  update public.payment_orders
  set status = case
      when p_status = 'approved' then 'approved'
      when p_status = 'refunded' then 'refunded'
      else status
    end,
    galiopay_payment_id = coalesce(p_payment_id, galiopay_payment_id),
    galiopay_raw = p_payload
  where reference_id = p_reference_id;

  if p_status = 'approved' and v_order.user_id is not null and v_order.course_id is not null then
    insert into public.enrollments (user_id, course_id, status)
    values (v_order.user_id, v_order.course_id, 'active')
    on conflict (user_id, course_id) do update
      set status = 'active';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. PROGRESO DEL ALUMNO (lesson_progress)
-- ---------------------------------------------------------------------
create table if not exists public.lesson_progress (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  lesson_id      uuid not null references public.lessons(id) on delete cascade,
  status         text not null default 'not_started'
                 check (status in ('not_started','in_progress','completed')),
  progress_pct   int not null default 0 check (progress_pct between 0 and 100),
  completed_at   timestamptz,
  updated_at     timestamptz not null default now(),
  unique (user_id, lesson_id)
);

create index if not exists idx_progress_user on public.lesson_progress(user_id);
create index if not exists idx_progress_lesson on public.lesson_progress(lesson_id);

-- Mantiene completed_at y updated_at consistentes
create or replace function public.touch_lesson_progress()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  if new.status = 'completed' and (tg_op = 'INSERT' or old.status is distinct from 'completed') then
    new.completed_at := now();
    new.progress_pct := 100;
  elsif new.status <> 'completed' then
    new.completed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_touch_lesson_progress on public.lesson_progress;
create trigger trg_touch_lesson_progress
  before insert or update on public.lesson_progress
  for each row execute procedure public.touch_lesson_progress();

-- ---------------------------------------------------------------------
-- 5. VISTA: % de avance del alumno por curso
-- ---------------------------------------------------------------------
create or replace view public.v_course_progress as
select
  e.user_id,
  e.course_id,
  count(l.id)                                                   as total_lessons,
  count(lp.id) filter (where lp.status = 'completed')            as completed_lessons,
  case when count(l.id) = 0 then 0
       else round(100.0 * count(lp.id) filter (where lp.status = 'completed') / count(l.id))
  end                                                             as progress_pct
from public.enrollments e
join public.modules m   on m.course_id = e.course_id
join public.lessons l   on l.module_id = m.id
left join public.lesson_progress lp
       on lp.lesson_id = l.id and lp.user_id = e.user_id
group by e.user_id, e.course_id;

comment on view public.v_course_progress is 'Avance (%) de cada alumno por curso, calculado en vivo';

-- ---------------------------------------------------------------------
-- 6. CERTIFICADOS — bloqueado hasta completar el curso, se emite solo
-- ---------------------------------------------------------------------
create sequence if not exists public.certificate_number_seq start 1000;

create table if not exists public.certificates (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  course_id          uuid not null references public.courses(id) on delete cascade,
  certificate_code   text unique not null,
  issued_at          timestamptz not null default now(),
  pdf_url            text,          -- se completa luego por una Edge Function que genera el PDF
  unique (user_id, course_id)
);

comment on table public.certificates is
  'Solo puede insertarse desde check_and_issue_certificate() (SECURITY DEFINER). Ningún alumno puede crear su propio registro: por eso queda "bloqueado" hasta terminar el 100% del curso.';

-- Genera un código legible tipo ACAD-2026-001007
create or replace function public.generate_certificate_code()
returns text
language plpgsql
as $$
begin
  return 'ACAD-' || to_char(now(), 'YYYY') || '-' ||
         lpad(nextval('public.certificate_number_seq')::text, 6, '0');
end;
$$;

-- Revisa si el alumno completó el 100% del curso y, si es así, emite el
-- certificado automáticamente (si todavía no existe uno).
create or replace function public.check_and_issue_certificate(p_user_id uuid, p_course_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total     int;
  v_completed int;
begin
  select count(l.id), count(lp.id) filter (where lp.status = 'completed')
    into v_total, v_completed
  from public.modules m
  join public.lessons l on l.module_id = m.id
  left join public.lesson_progress lp
         on lp.lesson_id = l.id and lp.user_id = p_user_id
  where m.course_id = p_course_id;

  if v_total > 0 and v_total = v_completed then
    insert into public.certificates (user_id, course_id, certificate_code)
    values (p_user_id, p_course_id, public.generate_certificate_code())
    on conflict (user_id, course_id) do nothing;
  end if;
end;
$$;

-- Se dispara cada vez que una lección pasa a "completed": revisa el curso
-- entero y emite el certificado automáticamente si ya está el 100%.
create or replace function public.trg_check_certificate_on_progress()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_course_id uuid;
begin
  if new.status = 'completed' then
    select m.course_id into v_course_id
    from public.lessons l
    join public.modules m on m.id = l.module_id
    where l.id = new.lesson_id;

    perform public.check_and_issue_certificate(new.user_id, v_course_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_certificate_on_progress on public.lesson_progress;
create trigger trg_certificate_on_progress
  after insert or update on public.lesson_progress
  for each row execute procedure public.trg_check_certificate_on_progress();

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.courses          enable row level security;
alter table public.modules          enable row level security;
alter table public.lessons          enable row level security;
alter table public.enrollments      enable row level security;
alter table public.payment_orders   enable row level security;
alter table public.lesson_progress  enable row level security;
alter table public.certificates     enable row level security;

-- PROFILES: cada quien ve y edita su propio perfil
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- COURSES / MODULES: contenido público (landing + catálogo)
drop policy if exists "courses_public_read" on public.courses;
create policy "courses_public_read" on public.courses
  for select using (is_published = true);

drop policy if exists "modules_public_read" on public.modules;
create policy "modules_public_read" on public.modules
  for select using (true);

-- LESSONS: preview libre; el resto solo si está inscripto
drop policy if exists "lessons_read_preview_or_enrolled" on public.lessons;
create policy "lessons_read_preview_or_enrolled" on public.lessons
  for select using (
    is_preview = true
    or exists (
      select 1 from public.modules m
      join public.enrollments e on e.course_id = m.course_id
      where m.id = lessons.module_id
        and e.user_id = auth.uid()
        and e.status = 'active'
    )
  );

-- ENROLLMENTS: el alumno ve y crea sus propias inscripciones
drop policy if exists "enrollments_select_own" on public.enrollments;
create policy "enrollments_select_own" on public.enrollments
  for select using (auth.uid() = user_id);

drop policy if exists "enrollments_insert_own" on public.enrollments;
create policy "enrollments_insert_own" on public.enrollments
  for insert with check (auth.uid() = user_id);

-- PAYMENT_ORDERS: el alumno puede ver sus pagos, pero no aprobarlos.
-- Crear/actualizar órdenes lo hacen las Edge Functions con service_role.
drop policy if exists "payment_orders_select_own" on public.payment_orders;
create policy "payment_orders_select_own" on public.payment_orders
  for select using (auth.uid() = user_id);

-- LESSON_PROGRESS: el alumno solo ve/edita su propio avance, y solo de
-- lecciones de cursos en los que está inscripto
drop policy if exists "progress_select_own" on public.lesson_progress;
create policy "progress_select_own" on public.lesson_progress
  for select using (auth.uid() = user_id);

drop policy if exists "progress_insert_own" on public.lesson_progress;
create policy "progress_insert_own" on public.lesson_progress
  for insert with check (
    auth.uid() = user_id
    and exists (
      select 1 from public.lessons l
      join public.modules m on m.id = l.module_id
      join public.enrollments e on e.course_id = m.course_id
      where l.id = lesson_progress.lesson_id
        and e.user_id = auth.uid()
        and e.status = 'active'
    )
  );

drop policy if exists "progress_update_own" on public.lesson_progress;
create policy "progress_update_own" on public.lesson_progress
  for update using (auth.uid() = user_id);

-- CERTIFICATES: el alumno solo puede LEER el suyo.
-- A propósito NO existe policy de insert/update/delete para usuarios:
-- la única forma de que aparezca un certificado es completando el curso
-- (la función check_and_issue_certificate corre con SECURITY DEFINER).
drop policy if exists "certificates_select_own" on public.certificates;
create policy "certificates_select_own" on public.certificates
  for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 8. SEED opcional: el curso de la landing con sus 9 módulos
-- ---------------------------------------------------------------------
insert into public.courses (slug, title, description)
values ('ia-generativa-2026', 'Curso de IA Generativa 2026',
        'Imagen, video, audio y publicidad con IA, de cero a un flujo de producción profesional.')
on conflict (slug) do nothing;

with c as (select id from public.courses where slug = 'ia-generativa-2026')
insert into public.modules (course_id, order_index, title, slug)
select c.id, v.order_index, v.title, v.slug
from c, (values
  (1,'Introducción a la IA generativa','intro-ia-generativa'),
  (2,'Generación de imágenes con IA','imagen'),
  (3,'Generación de video con IA','video'),
  (4,'Publicidad y marketing con IA','publicidad'),
  (5,'Audio, voz y podcasts con IA','audio'),
  (6,'Flujos de trabajo profesionales','flujos-pro'),
  (7,'Ética, derechos y buenas prácticas','etica'),
  (8,'Automatización y flujos con IA agentic','automatizacion'),
  (9,'IA para Redes Sociales y Calendario de Contenido','redes-sociales')
) as v(order_index, title, slug)
on conflict (course_id, order_index) do nothing;

-- Ejemplo: una lección por módulo (ajustar/expandir según el contenido real)
insert into public.lessons (module_id, order_index, title, is_preview)
select m.id, 1, m.title || ' — Clase 1', (m.order_index = 1)
from public.modules m
join public.courses c on c.id = m.course_id and c.slug = 'ia-generativa-2026'
on conflict (module_id, order_index) do nothing;

-- Lecciones reales que usa la landing/plataforma: cada page_key corresponde
-- a una pantalla del curso y permite guardar el avance desde el frontend.
with c as (
  select id from public.courses where slug = 'ia-generativa-2026'
),
lesson_seed as (
  select * from (values
    ('intro-ia-generativa', 1, 'intro',     'Introducción', true),
    ('imagen',              1, 'imagenes',  'Imágenes con IA', false),
    ('video',               1, 'video',     'Video con IA', false),
    ('publicidad',          1, 'publicidad','Publicidad con IA', false),
    ('audio',               1, 'audio',     'Audio & Voz con IA', false),
    ('flujos-pro',          1, 'flujos',    'Flujos Pro', false),
    ('etica',               1, 'etica',     'Ética & Derechos', false),
    ('automatizacion',      1, 'avanzado',  'Automatización IA', false),
    ('redes-sociales',      1, 'social',    'Redes & Calendario', false),
    ('imagen',              2, 'lab-img',   'Proyecto: Imagen', false),
    ('video',               2, 'lab-vid',   'Proyecto: Video', false),
    ('audio',               2, 'lab-aud',   'Proyecto: Audio', false),
    ('publicidad',          2, 'lab-ad',    'Proyecto: Publicidad', false),
    ('automatizacion',      2, 'lab-auto',  'Proyecto: Automatización', false),
    ('redes-sociales',      2, 'recursos',  'Recursos & Glosario', false)
  ) as v(module_slug, order_index, page_key, title, is_preview)
)
insert into public.lessons (module_id, order_index, title, page_key, is_preview)
select m.id, s.order_index, s.title, s.page_key, s.is_preview
from lesson_seed s
join public.modules m on m.slug = s.module_slug
join c on c.id = m.course_id
on conflict (module_id, order_index) do update
  set title = excluded.title,
      page_key = excluded.page_key,
      is_preview = excluded.is_preview;

-- =====================================================================
-- FIN
-- Flujo de uso típico desde el frontend (Supabase JS client):
--   1. supabase.from('enrollments').insert({ course_id })
--   2. Al terminar una clase:
--        supabase.from('lesson_progress').upsert({
--          lesson_id, status: 'completed'
--        })
--      → el trigger revisa el curso completo y, si es 100%, inserta el
--        certificado automáticamente. No hace falta llamar nada más.
--   3. Para mostrar el avance:
--        supabase.from('v_course_progress').select('*').eq('course_id', id)
--   4. Para saber si ya tiene certificado (y por lo tanto desbloquear la
--      descarga en la UI):
--        supabase.from('certificates').select('*').eq('course_id', id)
--      Si no devuelve filas, el certificado sigue bloqueado.
-- =====================================================================
