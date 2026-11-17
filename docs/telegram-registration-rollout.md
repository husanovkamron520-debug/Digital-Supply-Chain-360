# SupplyChain14 Telegram-first registration rollout

## User flow

1. In the Navyblue bot, a new user chooses **SupplyChain14 ro'yxatdan o'tish** (or sends `/sc14`).
2. The bot collects the user's full name and email address.
3. The bot creates a 30-minute, one-time registration intent using the service-role-only database RPC, then asks Supabase Auth to send an email magic link.
4. The user opens the email link. Supabase verifies the email and redirects to the website with a short-lived `tg_reg` token.
5. The website requires an explicit **Tasdiqlash va Telegramni ulash** click. The authenticated RPC verifies that the signed-in user's confirmed email matches the pending email before linking the Telegram ID.
6. The same Supabase account is then used in the website and Telegram Mini App. Existing website accounts can use the email magic-link login button.

The existing website-to-Telegram `/link CODE` flow remains available for already-created accounts.

## Required rollout steps (not yet applied)

1. Apply `supabase/migrations/20261117190000_telegram_email_registration.sql` to the Supabase project.
2. In Supabase **Authentication → URL Configuration**, allow the Worker website root URL as a redirect destination:
   `https://digital-supply-chain-360.husanovkamron520.workers.dev/`
3. Keep email confirmations enabled. Check that the **Magic Link** email template uses `{{ .ConfirmationURL }}` so the user receives a clickable link.
4. Configure custom SMTP before inviting real students. Supabase's built-in SMTP is restricted to organization team addresses and is not intended for production delivery. A transactional SMTP provider such as Resend, Brevo, Postmark, or Amazon SES can be used.
5. Confirm Render has the existing server-side `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` environment variables. The service-role key must never be exposed to the website or committed to Git.
6. Deploy the Worker and Render bot only after the migration, redirect allowlist, email template, and SMTP are ready.

## Security properties

- The pending token is 256-bit random material; only its SHA-256 digest is stored.
- Pending registrations expire after 30 minutes and are single-use.
- Only the service role can create pending registration rows.
- Only a signed-in, email-confirmed user can complete registration.
- The confirmed email must match the email entered in Telegram.
- The user must explicitly confirm the Telegram link on the website.
- A Telegram ID and a SupplyChain14 account cannot be linked to multiple accounts.
- Platform roles remain controlled by the existing profile/teacher process; Telegram registration creates a normal student profile and does not assign a class, team, or competition.

## Test checklist

- New email address: create account, receive link, confirm, link Telegram, enter website.
- Existing website account: request a magic link, confirm, link Telegram without creating a duplicate profile.
- Wrong signed-in email: completion is rejected.
- Expired or reused token: completion is rejected.
- Telegram ID already linked: a second registration is rejected.
- Email already linked to another Telegram ID: a second pending registration is rejected.
- Email delivery rate limit or SMTP failure: bot shows a retry message and does not claim registration succeeded.

## Current status

Code and migration are prepared in draft pull requests. The database migration, SMTP configuration, Worker deployment, and Render deployment have not been applied.
