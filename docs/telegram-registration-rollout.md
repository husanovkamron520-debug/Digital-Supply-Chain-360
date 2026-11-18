# SupplyChain14 Telegram-first registration rollout

## User flow

1. In the Navyblue bot, a new user chooses **SupplyChain14 ro'yxatdan o'tish** (or sends `/sc14`).
2. The bot collects only the user's full name. Telegram supplies the authenticated Telegram user ID; no email address or phone number is requested.
3. The bot creates a 256-bit, 30-minute, single-use registration intent through the service-role-only database RPC and returns a direct website URL containing only the one-time token.
4. The user opens the URL, creates a password, and creates a Supabase Auth account. The website derives an internal, non-deliverable identifier in the reserved `.invalid` domain from the Telegram ID; the user does not enter or need an email address.
5. The website requires an explicit **Telegram akkauntini ulash** click. The authenticated RPC consumes the one-time token and links the signed-in Supabase user to the Telegram ID.
6. Existing website users can choose **Sign in**, enter their existing email and password, and then confirm the Telegram link. The legacy website-to-Telegram `/link CODE` flow remains available.

## Important authentication design

Supabase Auth password sign-in expects an email-shaped identifier. For newly created Telegram-only accounts, the website uses `tg_<telegram-id>@telegram.invalid` internally. This is not a real mailbox and is never used for email delivery. The email field is hidden during Telegram-first account creation.

**Required Supabase Auth setting:** turn off email confirmation before testing or opening registration to students:

- Supabase Dashboard → Authentication → Sign In / Providers → Email.
- Disable **Confirm email**.
- Save the setting.

With confirmation disabled, password sign-up must return an authenticated session so the user can explicitly confirm the Telegram link. If sign-up returns no session, the website shows a configuration warning and does not claim the Telegram account was linked.

Telegram-only password recovery is implemented in the draft code: `/sc14_reset` in the bot issues a 256-bit, 15-minute single-use link; the website calls the `telegram-password-recovery` Edge Function, which atomically consumes the token and updates the Auth password with the server-side service-role key. The token hash is stored in a private table; service-role-only RPCs create and consume recovery intents. The website attempts to sign the user in after the reset. The Edge Function is configured with `verify_jwt = false` because its one-time token is the proof of authorization; CORS is restricted to the production Worker origin. This is still draft code and requires live deployment testing. Do not ask users to use the synthetic `.invalid` identifier as an email address.

## Required rollout steps (not yet applied)

1. Review and apply `supabase/migrations/20261117190000_telegram_email_registration.sql` to the Supabase project. It creates the registration and password-recovery pending tables plus their RPCs. The migration is in the draft branch only; it has not been applied to production.
2. In Supabase Auth, disable **Confirm email** as described above.
3. Confirm the Worker website root URL is served over HTTPS:
   `https://digital-supply-chain-360.husanovkamron520.workers.dev/`
4. Confirm Render has the existing server-side `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` environment variables. The service-role key must never be exposed to the website or committed to Git. The website continues to use only its public anon/publishable key.
5. Deploy the `telegram-password-recovery` Edge Function using `supabase/config.toml` (JWT verification disabled only for this token-verified endpoint), and confirm its required Supabase service-role environment is available.
6. Deploy the Worker and Render bot only after the migration, Auth setting, and Edge Function are ready.

## Security properties

- Telegram identity comes from the authenticated Telegram bot update, not a user-entered Telegram ID.
- The bot creates a 256-bit random token; only its SHA-256 digest is stored.
- Pending registrations expire after 30 minutes and are single-use.
- Only the service role can create pending registration rows.
- Only an authenticated Supabase user can complete registration, and the user must explicitly click the confirmation button.
- The pending token binds the signed-in account to the Telegram ID recorded by the bot. The website uses a token-protected RPC to retrieve the Telegram ID and derive the internal Supabase Auth identifier; the database token is authoritative for linking.
- A Telegram ID and a SupplyChain14 account cannot be linked to multiple accounts.
- Platform roles remain controlled by the existing profile/teacher process; Telegram registration creates a normal student profile and does not assign a class, team, or competition.
- No email address, SMTP provider, or paid domain is required for Telegram-first registration.

## Test checklist

- New Telegram user: open bot link, create password-only account, explicitly link Telegram, and enter website.
- Existing website account: choose sign in, enter existing email/password, explicitly link Telegram without creating a duplicate profile.
- Malformed Telegram ID or token: website rejects signup.
- Expired or reused token: completion is rejected.
- Telegram ID already linked: a second registration is rejected.
- Supabase Confirm email accidentally enabled: signup does not proceed to link confirmation and the website displays a configuration warning.
- Password recovery: `/sc14_reset` is accepted only in a private chat from a Telegram ID already linked to an account; the recovery link expires after 15 minutes, is single-use, and has a 60-second bot cooldown. Verify reset, automatic sign-in, expired/reused token rejection, and recovery after an Edge Function failure.

## Current status

The bot and website changes, including Telegram-only password recovery, are prepared in the existing draft pull requests. The migration, Supabase Auth setting, Edge Function deployment, Worker deployment, and Render deployment have not been applied. No production database or service has been changed.
