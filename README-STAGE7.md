# EATZY Stage 7 — Auth, Stall Protection, Menu Management

## Three deployed surfaces
- `customer/index.html` — customer ordering and tracking
- `owner/index.html` — owner/vendor login, order management, and full menu CRUD
- `display/index.html` — public token/status display

Root `index.html` redirects to the customer surface.

## Database
Run `STAGE7_SCHEMA.sql` on the EATZY Supabase project. It replaces the earlier permissive prototype schema with:
- Supabase Auth-backed profiles
- stalls and owner ownership
- menu items stored in Postgres
- atomic `place_order()` RPC with server-side prices, token generation and pickup OTP generation
- vendor-only status transitions
- server-side pickup OTP verification
- public-safe display queue
- RLS policies per role/stall
- Realtime publication entries for orders, menu items and display queue

## Security model
- Customer reads only their own orders/items/OTP secret.
- Vendor reads and manages only the stall they own.
- Display sees only token/status rows from `display_queue`.
- Pickup OTP is kept in `order_pickup_secrets`; vendor completion goes through `verify_pickup_otp()`.

## Configuration
`supabase-config.js` contains the Supabase project URL and publishable/anon key plus `EATZY_DEFAULT_STALL_SLUG`.
Do not put a service-role/secret key in client files.
