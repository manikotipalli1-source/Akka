# EATZY Owner Setup

1. Run `STAGE7_SCHEMA.sql` in Supabase SQL Editor. This resets the prototype schema.
2. In Supabase Dashboard → Authentication → Users, create the owner's email/password account.
3. Copy the user's UUID.
4. Run:

```sql
update public.profiles set role='vendor' where id='<OWNER_AUTH_UUID>';
update public.stalls set owner_id='<OWNER_AUTH_UUID>', name='Your Food Truck', is_active=true where slug='eatzy-main';
```

5. Open `owner.html` and sign in with the same email/password.
6. The owner can now edit the menu and manage only the orders for their stall.

Customer authentication is implemented with Supabase Phone OTP. Hosted Supabase requires an SMS/WhatsApp provider for real phone OTP delivery. Until that provider is configured, the customer page will show the provider/setup error rather than creating a fake authenticated session.
