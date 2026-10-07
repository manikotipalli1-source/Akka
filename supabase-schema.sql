-- EATZY Supabase database setup
-- Run this once in Supabase Dashboard -> SQL Editor.
-- Safe to re-run: policies are dropped/recreated.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key default gen_random_uuid(),
    phone text unique not null,
    name text,
    role text not null default 'customer'
        check (role in ('customer', 'vendor', 'display')),
    created_at timestamptz not null default now()
);

create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),
    customer_id uuid references public.profiles(id) on delete set null,
    token_number text not null,
    status text not null default 'Order Received'
        check (status in (
            'Order Received',
            'Preparing',
            'Ready for Pickup',
            'Completed'
        )),
    total_amount numeric(10,2) not null default 0,
    pickup_otp text not null,
    created_at timestamptz not null default now()
);

create table if not exists public.order_items (
    id uuid primary key default gen_random_uuid(),
    order_id uuid not null references public.orders(id) on delete cascade,
    menu_item_id text not null,
    item_name text not null,
    quantity integer not null check (quantity > 0),
    unit_price numeric(10,2) not null,
    created_at timestamptz not null default now()
);

create index if not exists orders_customer_id_idx
on public.orders(customer_id);

create index if not exists orders_created_at_idx
on public.orders(created_at);

create index if not exists order_items_order_id_idx
on public.order_items(order_id);

alter table public.profiles enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "prototype profiles insert" on public.profiles;
drop policy if exists "prototype profiles select" on public.profiles;
drop policy if exists "prototype orders insert" on public.orders;
drop policy if exists "prototype orders select" on public.orders;
drop policy if exists "prototype orders update" on public.orders;
drop policy if exists "prototype orders delete" on public.orders;
drop policy if exists "prototype order items insert" on public.order_items;
drop policy if exists "prototype order items select" on public.order_items;

create policy "prototype profiles insert"
on public.profiles for insert to anon, authenticated
with check (true);

create policy "prototype profiles select"
on public.profiles for select to anon, authenticated
using (true);

create policy "prototype orders insert"
on public.orders for insert to anon, authenticated
with check (true);

create policy "prototype orders select"
on public.orders for select to anon, authenticated
using (true);

create policy "prototype orders update"
on public.orders for update to anon, authenticated
using (true) with check (true);

create policy "prototype orders delete"
on public.orders for delete to anon, authenticated
using (true);

create policy "prototype order items insert"
on public.order_items for insert to anon, authenticated
with check (true);

create policy "prototype order items select"
on public.order_items for select to anon, authenticated
using (true);
