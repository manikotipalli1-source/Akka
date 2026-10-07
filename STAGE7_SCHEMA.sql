-- EATZY STAGE 7
-- Proper Supabase Auth + stall isolation + menu management + server-side pickup verification.
-- IMPORTANT: this is a reset script for the prototype. It intentionally removes the old
-- permissive Stage 3/6 tables and data. Run it only on the EATZY prototype project.

create extension if not exists pgcrypto;

drop view if exists public.owner_menu cascade;
drop view if exists public.display_orders cascade;
drop function if exists public.verify_pickup_otp(uuid,text) cascade;
drop function if exists public.set_order_status(uuid,text) cascade;
drop function if exists public.place_order(uuid,jsonb) cascade;
drop function if exists public.get_display_queue(uuid) cascade;
drop function if exists public.handle_new_user() cascade;
drop table if exists public.display_queue cascade;
drop table if exists public.order_pickup_secrets cascade;
drop table if exists public.order_items cascade;
drop table if exists public.orders cascade;
drop table if exists public.stall_counters cascade;
drop table if exists public.menu_items cascade;
drop table if exists public.stalls cascade;
drop table if exists public.profiles cascade;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text,
  name text,
  role text not null default 'customer' check (role in ('customer','vendor','display','admin')),
  created_at timestamptz not null default now()
);

create table public.stalls (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) on delete set null,
  name text not null,
  slug text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.menu_items (
  id text primary key,
  stall_id uuid not null references public.stalls(id) on delete cascade,
  name text not null,
  category text not null default 'Other',
  price numeric(10,2) not null check (price >= 0),
  image_url text,
  is_available boolean not null default true,
  stock integer not null default 0 check (stock >= 0),
  popularity integer not null default 0,
  tags_text text not null default '',
  is_veg boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.stall_counters (
  stall_id uuid primary key references public.stalls(id) on delete cascade,
  next_token integer not null default 101
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id) on delete cascade,
  stall_id uuid not null references public.stalls(id) on delete restrict,
  token_number text not null,
  status text not null default 'Order Received' check (status in ('Order Received','Preparing','Ready for Pickup','Completed')),
  total_amount numeric(10,2) not null default 0 check (total_amount >= 0),
  created_at timestamptz not null default now()
);
create unique index orders_stall_token_uidx on public.orders(stall_id, token_number);
create index orders_customer_idx on public.orders(customer_id, created_at desc);
create index orders_stall_idx on public.orders(stall_id, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  menu_item_id text references public.menu_items(id) on delete set null,
  item_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(10,2) not null check (unit_price >= 0)
);
create index order_items_order_idx on public.order_items(order_id);

create table public.order_pickup_secrets (
  order_id uuid primary key references public.orders(id) on delete cascade,
  pickup_otp text not null check (pickup_otp ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);

-- Public-safe projection for the TV/display. It contains no phone numbers, totals, items or OTPs.
create table public.display_queue (
  order_id uuid primary key references public.orders(id) on delete cascade,
  stall_id uuid not null references public.stalls(id) on delete cascade,
  token_number text not null,
  status text not null,
  created_at timestamptz not null
);
create index display_queue_stall_idx on public.display_queue(stall_id, created_at desc);

-- ---------- Auth profile trigger ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles(id, phone, name, role)
  values (new.id, new.phone, coalesce(new.raw_user_meta_data ->> 'name',''), 'customer')
  on conflict (id) do update
    set phone = excluded.phone,
        name = case when excluded.name <> '' then excluded.name else public.profiles.name end;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- ---------- Display queue synchronizer ----------
create or replace function public.sync_display_queue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'DELETE') then
    delete from public.display_queue where order_id = old.id;
    return old;
  end if;

  if new.status = 'Completed' then
    delete from public.display_queue where order_id = new.id;
  else
    insert into public.display_queue(order_id, stall_id, token_number, status, created_at)
    values(new.id, new.stall_id, new.token_number, new.status, new.created_at)
    on conflict (order_id) do update set
      stall_id = excluded.stall_id,
      token_number = excluded.token_number,
      status = excluded.status,
      created_at = excluded.created_at;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_to_display_queue on public.orders;
create trigger orders_to_display_queue
after insert or update or delete on public.orders
for each row execute procedure public.sync_display_queue();

-- ---------- Safe customer order creation ----------
create or replace function public.place_order(p_stall_id uuid, p_items jsonb)
returns table(order_id uuid, token_number text, status text, total_amount numeric, pickup_otp text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  counter integer;
  token text;
  new_order_id uuid;
  total numeric(10,2) := 0;
  otp text;
  item jsonb;
  qty integer;
  menu_id text;
  item_name text;
  item_price numeric(10,2);
  item_count integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to place an order';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty';
  end if;
  if not exists (select 1 from public.stalls where id=p_stall_id and is_active=true) then
    raise exception 'This stall is not available';
  end if;

  insert into public.stall_counters(stall_id, next_token)
  values(p_stall_id, 101)
  on conflict (stall_id) do nothing;

  select next_token into counter from public.stall_counters where stall_id=p_stall_id for update;
  token := 'A' || lpad(counter::text,3,'0');
  update public.stall_counters set next_token=counter+1 where stall_id=p_stall_id;

  new_order_id := gen_random_uuid();
  otp := lpad((floor(random()*9000)+1000)::int::text, 4, '0');

  select count(*) into item_count from jsonb_array_elements(p_items);
  if item_count = 0 then raise exception 'Your cart is empty'; end if;

  for item in select * from jsonb_array_elements(p_items) loop
    menu_id := item->>'menu_item_id';
    qty := greatest(1, coalesce((item->>'quantity')::int, 0));
    select name, price into item_name, item_price
    from public.menu_items
    where id=menu_id and stall_id=p_stall_id and is_available=true and stock >= qty;
    if not found then
      raise exception 'A selected item is unavailable or out of stock';
    end if;
    total := total + (item_price * qty);
  end loop;

  insert into public.orders(id, customer_id, stall_id, token_number, status, total_amount)
  values(new_order_id, auth.uid(), p_stall_id, token, 'Order Received', total);

  for item in select * from jsonb_array_elements(p_items) loop
    menu_id := item->>'menu_item_id';
    qty := greatest(1, coalesce((item->>'quantity')::int, 0));
    select name, price into item_name, item_price from public.menu_items where id=menu_id;
    insert into public.order_items(order_id, menu_item_id, item_name, quantity, unit_price)
    values(new_order_id, menu_id, item_name, qty, item_price);
    update public.menu_items set stock=greatest(0, stock-qty), updated_at=now() where id=menu_id;
  end loop;

  insert into public.order_pickup_secrets(order_id, pickup_otp) values(new_order_id, otp);

  return query select o.id, o.token_number, o.status, o.total_amount, s.pickup_otp, o.created_at
  from public.orders o join public.order_pickup_secrets s on s.order_id=o.id
  where o.id=new_order_id;
end;
$$;

-- ---------- Vendor status transitions ----------
create or replace function public.set_order_status(p_order_id uuid, p_status text)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders;
  owner_ok boolean;
begin
  select * into o from public.orders where id=p_order_id;
  if not found then raise exception 'Order not found'; end if;
  select exists(select 1 from public.stalls where id=o.stall_id and owner_id=auth.uid()) into owner_ok;
  if not owner_ok then raise exception 'You are not authorized to manage this order'; end if;
  if p_status not in ('Preparing','Ready for Pickup') then
    raise exception 'Invalid status transition';
  end if;
  if o.status='Order Received' and p_status <> 'Preparing' then
    raise exception 'Order must move to Preparing first';
  end if;
  if o.status='Preparing' and p_status <> 'Ready for Pickup' then
    raise exception 'Order must move to Ready for Pickup';
  end if;
  update public.orders set status=p_status where id=p_order_id returning * into o;
  return o;
end;
$$;

-- ---------- Pickup verification ----------
create or replace function public.verify_pickup_otp(p_order_id uuid, p_otp text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  select exists(
    select 1
    from public.orders o
    join public.stalls s on s.id=o.stall_id
    join public.order_pickup_secrets sec on sec.order_id=o.id
    where o.id=p_order_id
      and s.owner_id=auth.uid()
      and o.status='Ready for Pickup'
      and sec.pickup_otp=p_otp
  ) into ok;
  if ok then
    update public.orders set status='Completed' where id=p_order_id;
  end if;
  return ok;
end;
$$;

-- ---------- Safe public display API ----------
create or replace function public.get_display_queue(p_stall_id uuid)
returns table(order_id uuid, token_number text, status text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select order_id, token_number, status, created_at
  from public.display_queue
  where stall_id=p_stall_id and status in ('Order Received','Preparing','Ready for Pickup')
  order by created_at asc;
$$;

-- ---------- Grants / RLS ----------
grant usage on schema public to anon, authenticated;
grant select on public.stalls to anon, authenticated;
grant select on public.menu_items to anon, authenticated;
grant select on public.profiles to authenticated;
grant select on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.order_pickup_secrets to authenticated;
grant select on public.display_queue to anon, authenticated;
grant execute on function public.place_order(uuid,jsonb) to authenticated;
grant execute on function public.set_order_status(uuid,text) to authenticated;
grant execute on function public.verify_pickup_otp(uuid,text) to authenticated;
grant execute on function public.get_display_queue(uuid) to anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['profiles','stalls','menu_items','stall_counters','orders','order_items','order_pickup_secrets','display_queue'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Profiles: users can read their own profile only.
create policy profiles_select_own on public.profiles
for select to authenticated using (id=auth.uid());

-- Stalls: public can see active stall identity; vendor can see own stall.
create policy stalls_public_select on public.stalls
for select to anon, authenticated using (is_active=true or owner_id=auth.uid());

-- Menu: public may read available items; vendor may read all items in their stall.
create policy menu_public_select on public.menu_items
for select to anon, authenticated
using (is_available=true and exists(select 1 from public.stalls s where s.id=stall_id and s.is_active=true) or exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()));

create policy menu_vendor_insert on public.menu_items
for insert to authenticated
with check (exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()));

create policy menu_vendor_update on public.menu_items
for update to authenticated
using (exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()))
with check (exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()));

create policy menu_vendor_delete on public.menu_items
for delete to authenticated
using (exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()));

-- Orders: customer reads only own; vendor reads only own stall. Inserts/updates happen through RPCs.
create policy orders_customer_select on public.orders
for select to authenticated using (customer_id=auth.uid());
create policy orders_vendor_select on public.orders
for select to authenticated using (exists(select 1 from public.stalls s where s.id=stall_id and s.owner_id=auth.uid()));

-- Order items follow the order's ownership.
create policy order_items_customer_select on public.order_items
for select to authenticated using (exists(select 1 from public.orders o where o.id=order_id and o.customer_id=auth.uid()));
create policy order_items_vendor_select on public.order_items
for select to authenticated using (exists(select 1 from public.orders o join public.stalls s on s.id=o.stall_id where o.id=order_id and s.owner_id=auth.uid()));

-- OTP secrets are customer-readable only. Vendors validate via SECURITY DEFINER RPC.
create policy pickup_secret_customer_select on public.order_pickup_secrets
for select to authenticated using (exists(select 1 from public.orders o where o.id=order_id and o.customer_id=auth.uid()));

-- Public display queue contains no sensitive data.
create policy display_queue_public_select on public.display_queue
for select to anon, authenticated using (true);

-- ---------- Demo stall and menu seed ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.stalls WHERE slug='eatzy-main') THEN
    INSERT INTO public.stalls(id, owner_id, name, slug, is_active)
    VALUES ('00000000-0000-0000-0000-000000000001', NULL, 'EATZY Main Stall', 'eatzy-main', true);
  END IF;
  INSERT INTO public.stall_counters(stall_id, next_token)
  VALUES ('00000000-0000-0000-0000-000000000001', 101)
  ON CONFLICT (stall_id) DO NOTHING;
END $$;

-- Seed menu only when empty for the demo stall.
DO $$
DECLARE
  EATZY_STALL_ID uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.menu_items WHERE stall_id=EATZY_STALL_ID) THEN
    INSERT INTO public.menu_items(id, stall_id, name, category, price, image_url, is_available, stock, popularity, tags_text, is_veg, updated_at)
    VALUES
  ('t1', EATZY_STALL_ID, 'Idly', 'Tiffins', 50, 'https://as1.ftcdn.net/v2/jpg/02/31/01/44/1000_F_231014435_TpiaZpPzR9AGM6VjVgKy7T0fgYuo39oM.jpg', true, 8, 80, 'Veg', true, now()),
  ('t2', EATZY_STALL_ID, 'Mysore Bonda', 'Tiffins', 60, 'https://revi.b-cdn.net/wp-content/uploads/2017/02/6.jpg', true, 6, 64, 'Vegan', true, now()),
  ('t3', EATZY_STALL_ID, 'Poori', 'Tiffins', 70, 'https://www.indianhealthyrecipes.com/wp-content/uploads/2020/12/poori-puri-recipe.jpg', true, 7, 70, 'Keto', true, now()),
  ('t4', EATZY_STALL_ID, 'Chicken Chapati', 'Tiffins', 100, 'https://img.onmanorama.com/content/dam/mm/en/food/features/images/2024/4/30/chapati.jpg', true, 9, 64, 'Non-Veg,High Protein', false, now()),
  ('t5', EATZY_STALL_ID, 'Pesarattu Upma', 'Tiffins', 80, 'https://i.ytimg.com/vi/JYsG0LT5S9o/maxresdefault.jpg', true, 5, 80, 'Gluten Free', true, now()),
  ('t6', EATZY_STALL_ID, 'Masala Dosa', 'Tiffins', 90, 'https://revi.b-cdn.net/wp-content/uploads/2017/03/masala-dosa-vert.jpg', true, 9, 94, 'Sugar Free', true, now()),
  ('p1', EATZY_STALL_ID, 'Margherita Pizza', 'Pizza', 320, 'https://lilluna.com/wp-content/uploads/2020/12/margherita-pizza-resize-3-856x1198.jpg', true, 8, 80, 'Veg', true, now()),
  ('p2', EATZY_STALL_ID, 'Pepperoni Feast', 'Pizza', 420, 'https://tse1.mm.bing.net/th/id/OIP.XJO1NF6guXw-_i5ic9TG-QHaFh?pid=Api&P=0&h=180', true, 6, 64, 'Non-veg,High Protein', false, now()),
  ('p3', EATZY_STALL_ID, 'Cheese Burst', 'Pizza', 400, 'https://product-assets.faasos.io/production/product/image_1635166357602_image_1631125457040_Farm_Fresh_Cheese_Burst_Pizza.jpg', true, 7, 70, 'Veg,Vegan', true, now()),
  ('p4', EATZY_STALL_ID, 'Chicken Pizza', 'Pizza', 450, 'https://tse4.mm.bing.net/th/id/OIP.QfXdS4NwHgKcP0TmDhrcVwHaHa?pid=Api&P=0&h=180', true, 9, 64, 'Non-veg,Keto', false, now()),
  ('p5', EATZY_STALL_ID, 'Paneer Pizza', 'Pizza', 320, 'https://www.vegrecipesofindia.com/wp-content/uploads/2018/05/paneer-pizza-recipe-1.jpg', true, 5, 80, 'Veg', true, now()),
  ('p6', EATZY_STALL_ID, 'Keema Pizza', 'Pizza', 500, 'http://www.dominos.co.in/files/items/dish3-keema-do-pyaaza-copy-1346593698-427x298.jpg', true, 9, 94, 'Non-veg', false, now()),
  ('b1', EATZY_STALL_ID, 'Classic Beef Burger', 'Burgers', 250, 'https://images.unsplash.com/photo-1550547660-d9450f859349?q=80&w=1200&auto=format&fit=crop', true, 12, 56, 'Non-veg,High Protein', false, now()),
  ('b2', EATZY_STALL_ID, 'Crispy Veg Burger', 'Burgers', 190, 'https://images.unsplash.com/photo-1568901346375-23c9450c58cd?q=80&w=1200&auto=format&fit=crop', true, 10, 44, 'Veg,Vegan', true, now()),
  ('b3', EATZY_STALL_ID, 'Quinoa & Black Bean Veg Burger', 'Burgers', 300, 'https://www.thespruceeats.com/thmb/O8zqpGWgedbroCQev1cXNCP8vCY=/1500x0/filters:no_upscale():max_bytes(150000):strip_icc()/GettyImages-998869152-5bdfb1e64cedfd002673da55.jpg', true, 10, 44, 'Veg,Keto', true, now()),
  ('b4', EATZY_STALL_ID, 'Mutton Burger', 'Burgers', 350, 'https://corridorcafe.com/cdn/shop/files/IMG-8968__1_-removebg-preview.png?v=1709117574&width=1445', true, 10, 44, 'Non-Veg,Gluten Free', false, now()),
  ('b5', EATZY_STALL_ID, 'Pumpkin Seed Veg Burger', 'Burgers', 200, 'https://i.pinimg.com/originals/88/70/43/8870437f007cfc8dedb7580ef9e9d911.jpg', true, 10, 44, 'Veg', true, now()),
  ('b6', EATZY_STALL_ID, 'Crispy Fish Burger', 'Burgers', 280, 'https://www.myactivekitchen.com/wp-content/uploads/2019/03/close-shot-crispy-fish-burger-ships-recipe.600x900.jpg', true, 10, 44, 'Non-Veg,Sugar Free', false, now()),
  ('br1', EATZY_STALL_ID, 'Hyderabadi Chicken Biryani', 'Biryani', 260, 'https://images.slurrp.com/prod/recipe_images/transcribe/main%20course/Hyderabadi-Chicken-Biryani.webp', true, 9, 88, 'Non-veg,High Protein', false, now()),
  ('br2', EATZY_STALL_ID, 'Veg Biryani', 'Biryani', 220, 'https://i.ytimg.com/vi/JqP4wSWsYr4/maxresdefault.jpg', true, 5, 38, 'Veg', true, now()),
  ('br3', EATZY_STALL_ID, 'Mutton Biryani', 'Biryani', 450, 'https://anantha.in/wp-content/uploads/2020/03/Mutton-Biryani-Img.jpg', true, 5, 38, 'Non-Veg,Keto', false, now()),
  ('br4', EATZY_STALL_ID, 'Paneer Biryani', 'Biryani', 250, 'https://vegrecipeskitchen.com/wp-content/uploads/2023/11/Paneer-Biryani-recipe.jpg', true, 5, 38, 'Veg,Gluten Free', true, now()),
  ('br5', EATZY_STALL_ID, 'Fish Biryani', 'Biryani', 500, 'https://www.masala.tv/wp-content/uploads/2020/12/fish-biryanii.jpg', true, 5, 38, 'Non-Veg,Sugar Free', false, now()),
  ('br6', EATZY_STALL_ID, 'Mushroom Biryani', 'Biryani', 340, 'https://i2.wp.com/www.cookingfromheart.com/wp-content/uploads/2017/05/Chettinad-Mushroom-Biryani-2.jpg?resize=1024%2C683', true, 5, 38, 'Veg', false, now()),
  ('c1', EATZY_STALL_ID, 'Gobi Manchurian', 'Chinese', 180, 'https://www.indianveggiedelight.com/wp-content/uploads/2017/06/gobi-manchurian-featured.jpg', true, 11, 46, 'Veg', true, now()),
  ('c2', EATZY_STALL_ID, 'Veg Noodles', 'Chinese', 140, 'https://www.indianhealthyrecipes.com/wp-content/uploads/2016/05/veg-noodles-recipe-1-900x600.jpg', true, 14, 52, 'Veg,Low Calorie', true, now()),
  ('c3', EATZY_STALL_ID, 'Chicken 65', 'Chinese', 200, 'https://theflavoursofkitchen.com/wp-content/uploads/2021/08/Chicken-65-3-scaled.jpg', true, 14, 52, 'Non-Veg,High Calorie', false, now()),
  ('c4', EATZY_STALL_ID, 'Paneer Tikka', 'Chinese', 150, 'https://i0.wp.com/vegecravings.com/wp-content/uploads/2018/04/Paneer-Tikka-Recipe-Step-By-Step-Instructions.jpg?fit=2324%2C1944&quality=30&strip=all&ssl=1', true, 14, 52, 'Veg,Low Calorie', true, now()),
  ('c5', EATZY_STALL_ID, 'Black Pepper Shrimp', 'Chinese', 300, 'https://i.ytimg.com/vi/PMcJnDjo5ZY/maxresdefault.jpg', true, 14, 52, 'Non-Veg,Low Calorie', false, now()),
  ('c6', EATZY_STALL_ID, 'Smoked Chicken', 'Chinese', 350, 'https://www.recipedose.com/wp-content/uploads/2009/06/Murg-Malai-Tikka.jpg', true, 14, 52, 'Non-Veg,High Calorie', false, now()),
  ('d1', EATZY_STALL_ID, 'Chocolate Brownie', 'Desserts', 110, 'https://www.mashed.com/img/gallery/heres-why-you-should-make-your-brownies-with-dark-chocolate/intro-1605980145.jpg', true, 16, 72, 'Sugar Free', true, now()),
  ('d2', EATZY_STALL_ID, 'Gulab Jamun', 'Desserts', 90, 'https://newdelhi-restaurant.de/wp-content/uploads/2023/10/94.jpg', true, 8, 36, 'Gluten Free', true, now()),
  ('d3', EATZY_STALL_ID, 'Ice Cream', 'Desserts', 200, 'https://tse4.mm.bing.net/th/id/OIP.yeE6xAzrs9zdZAnO8DcgywHaFj?pid=Api&P=0&h=180', true, 8, 36, 'Keto', true, now()),
  ('d4', EATZY_STALL_ID, 'No-Bake Pineapple Cream', 'Desserts', 150, 'https://blogger.googleusercontent.com/img/b/R29vZ2xl/AVvXsEg3jynAc6qaWtNzWKVy9JaYzmCupp7ZmxOrt0eVJfugHIXcXQf_t30bEuvbqpXKxjlShWYbKGQy48MyBmeFfkxjrZfdC0THdcY-xq23PH4ASKOZUONGXJsSCsaMfDbZ-P6kUVwZb8C_C9bleXxwUwZBumHhkTSqGua5pMYRKsSJCUHsT8cuNSZnTR85F0wW/s16000/IMG_4893.jpeg', true, 8, 36, 'Vegan', true, now()),
  ('d5', EATZY_STALL_ID, 'Cheese Cake', 'Desserts', 100, 'https://tse4.mm.bing.net/th/id/OIP.W0LE5lO4-f1zqMIpoGw4BAHaE8?pid=Api&P=0&h=180', true, 8, 36, 'Veg', true, now()),
  ('d6', EATZY_STALL_ID, 'Rasmalai', 'Desserts', 150, 'https://img.freepik.com/premium-photo/bangladesh-rasmalai-dessert-cheese-dumplings-soaked-sweetened-saffroninfused-milk_162695-15426.jpg', true, 8, 36, 'Keto', true, now()),
  ('dr1', EATZY_STALL_ID, 'Thums Up', 'Drinks', 40, 'http://www.drinksindustryireland.ie/wp-content/uploads/2015/12/Soft-Drinkslow.jpg', true, 30, 95, 'Comfort', true, now()),
  ('dr2', EATZY_STALL_ID, 'Pure-Strawberry', 'Drinks', 130, 'https://bluristorante.com/wp-content/uploads/2019/04/The-6-Most-Popular-Italian-Drinks-and-Beverages.jpg', true, 12, 34, 'Vegan,High Protein', true, now()),
  ('dr3', EATZY_STALL_ID, 'Mocktail', 'Drinks', 110, 'https://tse2.mm.bing.net/th/id/OIP.w924G1Qro2FdgFpfhLuS3QHaE8?pid=Api&P=0&h=180', true, 12, 34, 'Vegan,Low Calorie', true, now()),
  ('dr4', EATZY_STALL_ID, 'Fresh Lime', 'Drinks', 90, 'https://img.freepik.com/premium-photo/fresh-lime-cocktail-zesty-refreshment-generative-ai_893571-4431.jpg', true, 12, 34, 'Vegan,Sugar Free', true, now()),
  ('dr5', EATZY_STALL_ID, 'Blueberry Smoothie', 'Drinks', 150, 'https://static.vecteezy.com/system/resources/previews/027/145/735/large_2x/close-up-view-of-blueberry-smoothies-perfect-for-drink-catalog-png.png', true, 12, 34, 'Vegan,Gluten Free', true, now()),
  ('dr6', EATZY_STALL_ID, 'Coca Cola', 'Drinks', 70, 'https://mybartender.com/wp-content/uploads/2022/10/cocktails-with-coke-740x494.jpg', true, 12, 34, 'Vegan,Keto', true, now()),
  ('mk1', EATZY_STALL_ID, 'Pasta Meal Kit', 'Meal Kits', 210, 'https://m.media-amazon.com/images/I/51VLHkgVqcL._AC_.jpg', true, 7, 14, '', true, now()),
  ('mk2', EATZY_STALL_ID, 'Biryani Meal Kit', 'Meal Kits', 240, 'https://m.media-amazon.com/images/I/71M9ZCDILTL._AC_SX569_.jpg', true, 6, 11, '', true, now()),
  ('mk3', EATZY_STALL_ID, 'Instant Parota', 'Meal Kits', 200, 'https://tse4.mm.bing.net/th/id/OIP.6rhRIlSBvvVib4IT8iIyEQHaHa?pid=Api&P=0&h=180', true, 6, 11, '', false, now()),
  ('mk4', EATZY_STALL_ID, 'Hyderabad Chicken Biryani Kit', 'Meal Kits', 300, 'https://snnfoods.com/cdn/shop/files/7_2048x2048.png?v=1701775513', true, 6, 11, '', false, now()),
  ('mk5', EATZY_STALL_ID, 'Pizza Kit', 'Meal Kits', 250, 'https://static.wixstatic.com/media/62cf85_a2954815891f4ff5b5428bd19b92ca0d~mv2.png/v1/fill/w_980,h_796,al_c,q_90,usm_0.66_1.00_0.01,enc_auto/62cf85_a2954815891f4ff5b5428bd19b92ca0d~mv2.png', true, 6, 11, '', false, now()),
  ('mk6', EATZY_STALL_ID, 'PopCorn Kit', 'Meal Kits', 150, 'http://5.imimg.com/data5/SELLER/Default/2024/5/417603792/AK/GN/IK/9447361/instant-popcorn-kit-1000x1000.jpg', true, 6, 11, '', true, now())
    ;
  END IF;
END $$;

-- Realtime: orders/menu_items/display_queue. Ignore duplicate-object errors if already enabled in the project.
DO $$
BEGIN
  BEGIN alter publication supabase_realtime add table public.orders; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN alter publication supabase_realtime add table public.menu_items; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN alter publication supabase_realtime add table public.display_queue; EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

-- Setup owner after creating a user in Supabase Auth:
--   update public.profiles set role='vendor' where id='<AUTH_USER_UUID>';
--   update public.stalls set owner_id='<AUTH_USER_UUID>', name='Your Stall Name' where slug='eatzy-main';
