# EATZY Cloudflare Deployment

## Recommended: GitHub -> Cloudflare Pages

This project is a static HTML site with three surfaces:
- /customer/
- /owner/
- /display/

### Cloudflare Pages settings
- Framework preset: None
- Build command: (leave empty)
- Build output directory: `/` (the repository root)
- Production branch: `main`

Connect the GitHub repository to Cloudflare Pages. Every push to `main` will create a new production deployment.

## Supabase
The frontend uses the Supabase project configured in `supabase-config.js`. Do not put service-role or secret keys in this file.

## Surface URLs after deployment
- https://<project>.pages.dev/customer/
- https://<project>.pages.dev/owner/
- https://<project>.pages.dev/display/

## Optional custom domains
You can later map separate subdomains, for example:
- order.example.com -> /customer
- owner.example.com -> /owner
- display.example.com -> /display

See Cloudflare Pages custom domains documentation.
