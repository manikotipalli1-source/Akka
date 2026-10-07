# EATZY Owner-Authenticated Display

The public display is now protected with the same Supabase owner/vendor email + password used by the Owner portal.

## Setup

1. Keep your existing `STAGE7_SCHEMA.sql` as-is if it is already installed.
2. Run `STAGE7_DISPLAY_AUTH_PATCH.sql` once in Supabase SQL Editor.
3. Open `/display/`.
4. Sign in using the same owner credentials as `/owner/`.
5. The display automatically identifies the owner's assigned stall and only loads that stall's queue.

## Behavior

- The display keeps the same TV-friendly Preparing / Ready for Pickup UI.
- No customer phone numbers, item details, totals, or pickup OTPs are shown.
- A Supabase session is reused after the first successful login, so the TV/tablet does not need to be logged in repeatedly unless the session expires or the owner logs out.
- Realtime updates continue through `display_queue`.
- The SQL patch blocks anonymous queue access and restricts the display RPC to the authenticated owner's active stall.
