# Digital Supply Chain 360

A mobile-first, interactive supply-chain learning platform. The project is being developed in two layers:

- **Control tower:** interactive 3D supply-chain network and simulated operational KPIs.
- **Classroom platform:** teacher/student accounts, class join codes, operational roles, scenarios and saved activity.

All supply-chain figures and transactions are simulated for classroom learning. The platform is not connected to live company systems.

## Current project structure

- `index.html`, `styles.css`, `app.js` — 3D control-tower interface.
- `auth.js` — Supabase sign-up, sign-in, session handling and role display.
- `supabase-config.js` — public Supabase URL/key configuration template.
- `supabase/schema.sql` — database schema, role model, class join function and Row Level Security policies.

## Platform architecture

- **Cloudflare Pages** — static frontend hosting.
- **Supabase Auth** — sign-up and sign-in.
- **Supabase PostgreSQL** — profiles, classrooms, memberships, scenarios, orders, inventory, shipments and activity history.
- **Row Level Security (RLS)** — database-side access control.

The frontend will use only the Supabase project URL and the public anon/publishable key. Never put a Supabase `service_role` key in browser code or commit it to GitHub.

## Database setup

1. Create a Supabase project.
2. Open **SQL Editor → New query**.
3. Copy and run the complete contents of `supabase/schema.sql`.
4. In **Authentication → Users**, create or invite the first account that will act as the teacher.
5. Promote that account from the SQL Editor, replacing the email with the teacher's actual login email:

   ```sql
   update public.profiles
   set platform_role = 'teacher'
   where id = (
     select id from auth.users
     where email = 'teacher@example.com'
   );
   ```

6. Copy the **Project URL** and **anon/public or publishable key** from Project Settings → API. Never copy the service-role/secret key into the browser or GitHub.
7. Replace the two placeholder values in `supabase-config.js` with the Project URL and public key.
8. In Authentication → URL Configuration, add your deployed website URL to the allowed Site URL / Redirect URLs after hosting is set up.

New sign-ups receive the `student` role automatically. Students join a classroom through the `join_classroom(code)` database function; they cannot create their own teacher role or forge membership rows.

## Run locally

Because the app uses JavaScript modules, serve the folder through a local web server:

```bash
python -m http.server 8000
```

Then open http://localhost:8000.

## Deploy frontend

Cloudflare Pages can connect directly to this GitHub repository:

1. Create a Pages project and connect this repository.
2. Framework preset: **None**.
3. Build command: leave empty.
4. Build output directory: `/` (repository root).
5. Add the Supabase frontend configuration as public environment variables only if/when the app build is configured to read them.

The frontend now contains the Supabase authentication screen. It becomes usable only after `supabase/schema.sql` is applied and `supabase-config.js` contains the correct Project URL and public key. Classroom management and database-backed operational workflows are being built in subsequent stages.

## Learning note

This is an educational simulation. It is intended for classroom exercises and must not be used for real operational or financial decisions.
