-- EATZY Stage 7 - Owner-authenticated display patch
-- Run this AFTER STAGE7_SCHEMA.sql.
-- The display now requires the owner/vendor's Supabase session.

-- Prevent anonymous callers from using the display queue API.
revoke execute on function public.get_display_queue(uuid) from anon;
grant execute on function public.get_display_queue(uuid) to authenticated;

-- Only authenticated owners should be able to read display_queue rows.
revoke select on public.display_queue from anon;
grant select on public.display_queue to authenticated;

drop policy if exists display_queue_public_select on public.display_queue;
drop policy if exists display_queue_owner_select on public.display_queue;

create policy display_queue_owner_select
on public.display_queue
for select
to authenticated
using (
  exists (
    select 1
    from public.stalls s
    where s.id = display_queue.stall_id
      and s.owner_id = auth.uid()
      and s.is_active = true
  )
);

-- Secure the RPC itself so an authenticated owner can only query its own active stall.
create or replace function public.get_display_queue(p_stall_id uuid)
returns table(order_id uuid, token_number text, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.stalls s
    where s.id = p_stall_id
      and s.owner_id = auth.uid()
      and s.is_active = true
  ) then
    raise exception 'You are not authorized to access this stall display';
  end if;

  return query
  select dq.order_id, dq.token_number, dq.status, dq.created_at
  from public.display_queue dq
  where dq.stall_id = p_stall_id
    and dq.status in ('Order Received','Preparing','Ready for Pickup')
  order by dq.created_at asc;
end;
$$;

revoke execute on function public.get_display_queue(uuid) from anon;
grant execute on function public.get_display_queue(uuid) to authenticated;
