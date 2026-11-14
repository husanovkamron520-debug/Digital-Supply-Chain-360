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


### SupplyChain14 Team Competition Engine

A classroom competition module that turns each student team into an isolated, company-model supply chain. It is separate from the legacy demonstration control-tower KPIs.

**Company cases**
- Toyota — lean automotive sourcing and production.
- Amazon — omnichannel fulfilment and inventory positioning.
- IKEA — global flat-pack sourcing and longer replenishment lead times.
- Coca-Cola — high-volume beverage production and distribution.

These are educational simulations based on publicly known business models, not official company integrations or partnerships. Each model has different capacity, baseline lead time, product economics, starting inventory, supplier offers, and inventory holding-cost rates.

**Teacher workflow**
1. Create a competition for a classroom.
2. Generate 2–4 balanced teams. The automatic four-team setup assigns all classroom students once and distributes five roles per team: Procurement, Supplier Relations, Manufacturer, Warehouse, and Transport.
3. Generate the standard five-role task pack or create custom tasks.
4. Start, pause/resume, and advance the competition through four rounds. Each round advances the simulation clock by three virtual days.
5. Review submitted work and evaluate decision rationales.
6. Calculate round scores and finalise the competition after the last round.

**Student workflow**
- Work only inside the assigned company team and role.
- Compare supplier price, lead time, and reliability; place purchase orders.
- Receive stock only when the simulated supplier availability date has elapsed.
- Convert raw materials into finished goods within company production capacity.
- Dispatch available finished goods, then confirm delivery after the simulated transport ETA.
- Submit role tasks and explain operational decisions.

**Live operational data**
- Team-specific suppliers, inventory, purchase orders, customer orders, production runs, shipments, finance ledger, and event history.
- Purchase, production, transport, revenue, and inventory carrying costs update team cash.
- Supplier reliability adds a risk buffer to the availability date; round progression unlocks receipts and deliveries.
- OTIF uses delivered quantities against on-time quantities, including orders already due but still undelivered.
- Team score uses weighted service (25%), cost (20%), inventory health (15%), lead time (15%), productivity (10%), and evaluated decision quality (15%). Score coverage is shown; a live total is withheld until delivery, production, and evaluated decision evidence exists. Finalisation records zero for a team with insufficient evidence rather than inventing performance.
- Individual rankings use teacher-evaluated decision scores. The public leaderboard exposes aggregate team and individual results, not other teams' operational records or decision rationales.

Competition writes are performed through role-validated database RPCs. RLS isolates operational records by team; teachers can review the whole classroom. Direct client writes to competition tables are revoked.

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
- `competition.js` — teacher/student competition setup, role tasks, operations, rankings, and round controls.
- `supabase-config.js` — public Supabase URL and publishable key.
- `supabase/` — baseline schema and incremental SQL changes, including `competition_engine.sql` and `competition_operations.sql`.
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

The database includes profiles, classrooms, memberships, scenarios, orders, shipments, inventory, activity logs, suppliers, purchase orders, and the isolated team competition engine.

- `supabase/schema.sql` is the baseline schema.
- `supabase/competition_engine.sql` creates the competition foundation after the classroom/core schema.
- `supabase/competition_operations.sql` contains the applied team operations, round clock, role workflows, live metrics, and leaderboard migrations in dependency order.
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

A successful GitHub deployment confirms syntax validation and deployment, not full manual browser QA. See `docs/CLASSROOM_QA_CHECKLIST.md` and `docs/COMPETITION_QA_CHECKLIST.md` for the detailed classroom and competition test plans.

## Important limitation

SupplyChain14 is for learning and classroom simulation only. The control-tower dashboard still contains demonstration KPIs and events; it is not a live supply-chain monitoring system and must not be used for real operational or financial decisions.
