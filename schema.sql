-- GEOMETRY CHALLENGE: jalankan seluruh file ini di Supabase > SQL Editor
create table sessions(
  id uuid primary key default gen_random_uuid(),
  pin text unique not null,
  name text not null default 'Geometry Challenge',
  host uuid not null default auth.uid(),
  status text not null default 'lobby',          -- lobby | question | finished
  current_q int not null default 0,
  q_started timestamptz,
  time_limit int not null default 30,
  show_lb boolean not null default false,
  created_at timestamptz default now());
create table players(
  id uuid not null, session_id uuid not null references sessions on delete cascade,
  name text not null, joined_at timestamptz default now(),
  primary key(session_id,id));
create unique index on players(session_id, lower(name));      -- cegah nama ganda
create table questions(q int primary key, body text, a text, b text, c text, d text, pic text);
create table answer_key(q int primary key references questions, key text not null);
create table answers(
  session_id uuid, player_id uuid, q int,
  choice text check (choice in ('A','B','C','D')),
  correct boolean, ms int,
  primary key(session_id,player_id,q),                        -- 1 jawaban per soal
  foreign key(session_id,player_id) references players(session_id,id) on delete cascade);

create function is_host(sid uuid) returns boolean language sql security definer stable set search_path=public
 as $$select exists(select 1 from sessions where id=sid and host=auth.uid())$$;
create function is_member(sid uuid) returns boolean language sql security definer stable set search_path=public
 as $$select exists(select 1 from players where session_id=sid and id=auth.uid())$$;

alter table sessions enable row level security;  alter table players enable row level security;
alter table questions enable row level security; alter table answer_key enable row level security;
alter table answers enable row level security;
create policy s_sel on sessions for select using (host=auth.uid() or is_member(id));
create policy p_sel on players  for select using (is_host(session_id) or is_member(session_id));
create policy p_del on players  for delete using (is_host(session_id));
create policy q_sel on questions for select using (true);
create policy a_sel on answers  for select using (is_host(session_id));
-- answer_key: tanpa policy = tidak bisa dibaca siapa pun lewat API (hanya fungsi server)

create function create_session(p_name text,p_time int,p_lb boolean) returns sessions
language plpgsql security definer set search_path=public as $$
declare s sessions; p text;
begin
  if coalesce((auth.jwt()->>'is_anonymous')::boolean,true) then raise exception 'Hanya guru yang boleh membuat sesi'; end if;
  loop p:=lpad(floor(random()*1000000)::int::text,6,'0'); exit when not exists(select 1 from sessions where pin=p); end loop;
  insert into sessions(pin,name,time_limit,show_lb) values(p,left(p_name,60),greatest(p_time,5),p_lb) returning * into s;
  return s;
end $$;

create function advance_session(p_id uuid,p_end boolean default false) returns sessions
language plpgsql security definer set search_path=public as $$
declare s sessions; n int;
begin
  select * into s from sessions where id=p_id and host=auth.uid();
  if not found then raise exception 'Bukan host sesi ini'; end if;
  select count(*) into n from questions;
  if p_end or s.status='finished' or s.current_q>=n then
    update sessions set status='finished' where id=p_id returning * into s;
  else
    update sessions set status='question', current_q=current_q+1, q_started=now() where id=p_id returning * into s;
  end if;
  return s;
end $$;

create function join_session(p_pin text,p_name text) returns players
language plpgsql security definer set search_path=public as $$
declare s sessions; pl players; nm text:=trim(p_name);
begin
  select * into s from sessions where pin=trim(p_pin);
  if not found or s.status='finished' then raise exception 'PIN tidak ditemukan atau sesi sudah selesai'; end if;
  select * into pl from players where session_id=s.id and id=auth.uid();
  if found then return pl; end if;                              -- bergabung kembali
  if s.status<>'lobby' then raise exception 'Permainan sudah dimulai'; end if;
  if length(nm)<2 then raise exception 'Nama terlalu pendek'; end if;
  begin insert into players(id,session_id,name) values(auth.uid(),s.id,left(nm,30)) returning * into pl;
  exception when unique_violation then raise exception 'Nama sudah dipakai di sesi ini'; end;
  return pl;
end $$;

create function submit_answer(p_sid uuid,p_q int,p_choice text) returns void
language plpgsql security definer set search_path=public as $$
declare s sessions; ms int;
begin
  select * into s from sessions where id=p_sid;
  if not found or s.status<>'question' or s.current_q<>p_q then raise exception 'Soal tidak aktif'; end if;
  if not is_member(p_sid) then raise exception 'Bukan peserta'; end if;
  ms:=(extract(epoch from now()-s.q_started)*1000)::int;
  if ms>(s.time_limit+2)*1000 then raise exception 'Waktu habis'; end if;
  insert into answers values(p_sid,auth.uid(),p_q,p_choice,(select key=p_choice from answer_key where q=p_q),ms)
  on conflict do nothing;
end $$;

create function q_stats(p_sid uuid,p_q int) returns table(choice text,n bigint,ok boolean)
language sql security definer stable set search_path=public as $$
  select choice,count(*),bool_or(correct) from answers where session_id=p_sid and q=p_q and is_host(p_sid) group by choice $$;

create function leaderboard(p_sid uuid) returns table(player_id uuid,name text,correct int,wrong int,score int,nilai int,total_ms bigint,rank bigint)
language sql security definer stable set search_path=public as $$
  select x.*, rank() over(order by x.score desc, x.total_ms asc) from (
    select p.id,p.name,
      count(a.q) filter(where a.correct)::int,
      ((select count(*) from questions)-count(a.q) filter(where a.correct))::int,
      count(a.q) filter(where a.correct)::int,
      round(100.0*count(a.q) filter(where a.correct)/(select count(*) from questions))::int,
      coalesce(sum(a.ms),0)::bigint
    from players p left join answers a on a.session_id=p.session_id and a.player_id=p.id
    where p.session_id=p_sid and (is_host(p_sid) or is_member(p_sid)) group by p.id,p.name) x
  order by 8 $$;

alter publication supabase_realtime add table sessions, players, answers;

insert into questions values
(1,'Benda yang bentuknya seperti bola adalah ....','Dadu','Bola sepak','Kotak pensil','Buku','⚽'),
(2,'Bangun ruang yang memiliki bentuk seperti kaleng susu adalah ....','Tabung','Kubus','Balok','Bola','🥫'),
(3,'Dadu memiliki bentuk bangun ruang ....','Bola','Tabung','Kubus','Kerucut','🎲'),
(4,'Bagian permukaan yang membatasi bangun ruang disebut ....','Sudut','Sisi','Garis','Titik','🧊'),
(5,'Bangun ruang kubus memiliki berapa sisi?','4 sisi','5 sisi','6 sisi','8 sisi','🧊'),
(6,'Bagian tempat dua sisi bertemu dan membentuk pojok disebut ....','Sisi','Sudut','Lingkaran','Permukaan','📦'),
(7,'Perhatikan benda berbentuk kotak seperti kardus. Bagian pojok kardus menunjukkan ....','Sisi','Sudut','Permukaan','Lingkaran','📦');
insert into answer_key values (1,'B'),(2,'A'),(3,'C'),(4,'B'),(5,'C'),(6,'B'),(7,'B');
