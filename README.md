# SupplyChain14

A mobile-first, interactive supply-chain learning and simulation platform for university classrooms.

SupplyChain14 combines a simulated end-to-end control tower with classroom workflows. It is an educational environment: operational quantities, transactions, and dashboard KPIs are simulated and are not connected to real company systems.

## Live environment

- **Website:** https://digital-supply-chain-360.husanovkamron520.workers.dev/
- **Hosting:** Cloudflare Workers Static Assets
- **Backend:** Supabase Auth + PostgreSQL + Row Level Security
- **Deployment:** GitHub Actions on every push to `main`

The Cloudflare Worker currently retains the technical name `digital-supply-chain-360`; the product brand shown in the interface is SupplyChain14.

## Current modules

### Control tower
- Interactive 3D supply-chain network and process explorer.
- Simulated KPIs and demonstration activity stream.
- Educational-simulation disclaimer; dashboard figures are not live operational data.

### Classroom and roles
- Teacher and student accounts, classroom creation, and join codes.
- Teacher assignment of Supplier, Manufacturer, Warehouse, Transport, Customer, and Retailer roles.
- Classroom-scoped records and role checks enforced by database functions and RLS.

### Operations and inventory
- Supply orders, shipment planning, and validated status transitions.
- Teacher-only order status changes; Transport role can manage shipment statuses.
- SKU/item register, opening quantities, reorder levels, receive/issue movements, and activity history.

### Procurement and supplier workflow
- Supplier register and purchase orders.
- Manufacturer role can create purchase orders.
- Linked supplier accounts can accept/reject only their own purchase orders.
- Warehouse role can receive accepted orders into inventory.
- Partial receipts update received quantity and stock; rejected linked-supplier orders cannot be received.
- Teachers retain classroom oversight and procurement control.

### Scenario Simulation Lab
Teachers can launch Supplier Delay, Demand Spike, and Route Disruption scenarios. Students submit a decision and rationale; scores and feedback are calculated server-side. Scenario-tagged orders, shipments, and inventory are isolated from normal operational records.

### Teacher analytics
Classroom-level order, shipment, inventory, scenario, and participation metrics. Scenario records are excluded from baseline operational KPIs.

## Repository structure

- `index.html` — app shell and workspace markup.
- `styles.css` — responsive interface styling.
- `app.js` — control tower and main interface behavior.
- `auth.js` — Supabase authentication and session handling.
- `classroom.js` — classroom creation/joining and role assignment.
- `inventory.js` — inventory workspace.
- `operations.js` — orders and shipments.
- `procurement.js` — suppliers and purchase orders.
- `scenarios.js` — scenario launch, student decisions, and results.
- `analytics.js` — teacher analytics.
- `supabase-config.js` — public Supabase URL and publishable key.
- `supabase/` — baseline schema and incremental SQL changes.
- `.github/workflows/deploy.yml` — syntax validation and Cloudflare deployment.
- `wrangler.toml` — Cloudflare Worker/static-assets configuration.

## Deployment

A push to `main` runs `.github/workflows/deploy.yml`:
1. Checks JavaScript syntax.
2. Copies HTML, CSS, and JavaScript files into `dist/`.
3. Deploys static assets to Cloudflare Workers.

Required GitHub Actions configuration:
- Secret: `CLOUDFLARE_API_TOKEN`
- Repository variable: `CLOUDFLARE_ACCOUNT_ID`

Never commit Cloudflare tokens, Supabase service-role keys, or other secrets. Browser code may contain only the Supabase project URL and public publishable/anon key.

## Supabase setup and SQL

The database includes profiles, classrooms, memberships, scenarios, orders, shipments, inventory, activity logs, suppliers, and purchase orders.

- `supabase/schema.sql` is the baseline schema.
- Other SQL files are incremental changes for modules, state transitions, indexes, RLS, grants, and security hardening.
- For an existing project, apply only changes that have not already been applied, in their dependency order. Do not blindly rerun every file against a populated production database.

After setup:
1. Configure the project URL and public publishable key in `supabase-config.js`.
2. Add the deployed website URL to Supabase Authentication URL configuration.
3. Create the first teacher account and assign its platform role through a trusted administrative process.
4. Keep RLS enabled on every exposed table.
5. Enable leaked-password protection in Supabase Authentication → Password Security.

Privileged database functions must validate the signed-in user, classroom membership, and operational role before changing data. Do not weaken RLS or expose direct client-side write permissions to bypass RPC validation.

## Local development

Serve the project folder with a local web server (ES modules require HTTP):

```bash
python -m http.server 8000
```

Then open http://localhost:8000.

## Release and classroom QA

Before calling a release classroom-ready, test on an actual phone:
- Teacher sign-up/login, classroom creation, join code, and role assignment.
- Student join and role-specific navigation/actions.
- Supplier visibility and responses restricted to its own purchase orders.
- Manufacturer PO creation and Warehouse receipt of accepted orders.
- Inventory receipt/issue, order/shipment transitions, and activity history.
- Scenario launch, student decisions, completion, and isolation from baseline data.
- Teacher analytics, refresh, sign-out/sign-in, empty/error states, and narrow-screen layout.

A successful GitHub deployment confirms syntax validation and deployment, not full manual browser QA. See `docs/CLASSROOM_QA_CHECKLIST.md` for the detailed test plan.

## Important limitation

SupplyChain14 is for learning and classroom simulation only. The control-tower dashboard still contains demonstration KPIs and events; it is not a live supply-chain monitoring system and must not be used for real operational or financial decisions.
