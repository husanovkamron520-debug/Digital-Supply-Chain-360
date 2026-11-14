# SupplyChain14 Competition Engine QA Checklist

Run this checklist with a dedicated teacher account and at least 20 test student accounts before using the module in a live class. Use test data, not a real operational classroom.

## 1. Teacher setup

- [ ] Teacher can create a competition for an owned classroom.
- [ ] Four-team auto setup creates exactly four company teams.
- [ ] All classroom students are assigned exactly once.
- [ ] With 20 students, each team has five students and one each of Procurement, Supplier, Manufacturer, Warehouse, and Transport.
- [ ] Each team receives its own company profile, suppliers, inventory, cash balance, and three customer orders.
- [ ] Standard task pack creates five role-specific tasks per team (20 tasks for four teams).
- [ ] Start is blocked if any student is unassigned, a team is empty, or team sizes differ by more than one.
- [ ] Start creates four rounds and initializes the virtual clock.

## 2. Student access and isolation

- [ ] Each student sees only their assigned team, role, tasks, decisions, and operational records.
- [ ] Students cannot read another team's suppliers, purchase orders, inventory, orders, production, shipments, ledger, or event history.
- [ ] Students can see the aggregate competition leaderboard and evaluated individual rankings.
- [ ] Student A cannot submit a task assigned to Student B or to a different role.
- [ ] Students cannot directly insert/update/delete competition tables.
- [ ] An unauthenticated user cannot call competition RPCs.

## 3. Operational flow

- [ ] Supplier role can negotiate lead time, unit cost, and reliability only for their own team's suppliers.
- [ ] Procurement role can place a purchase order only with a supplier belonging to their own team.
- [ ] Purchase-order expected and availability dates reflect lead time and reliability.
- [ ] Warehouse cannot receive a purchase order before the virtual availability date.
- [ ] Receiving stock increases inventory and reduces team cash; partial receipts work correctly.
- [ ] Manufacturer cannot exceed per-round capacity or consume unavailable raw material.
- [ ] Production reduces raw material, increases finished goods, and charges conversion cost.
- [ ] Transport cannot dispatch more units than available finished stock or the remaining order quantity.
- [ ] Transport cannot confirm delivery before the simulated ETA.
- [ ] Delivery updates the customer order, recognises revenue, and records on-time/late status.
- [ ] Supplier, purchase, production, transport, revenue, and holding-cost events appear in the correct team's history.

## 4. Rounds, tasks, and scoring

- [ ] Pause blocks student operational RPCs and task submissions; resume restores them.
- [ ] Advancing a round moves virtual time forward three days and charges company-specific inventory holding cost.
- [ ] Round deadlines are shown on standard role tasks; submitted round is recorded.
- [ ] Late task submissions are identifiable to the teacher.
- [ ] Team metrics use actual competition records, not the legacy demo KPIs.
- [ ] OTIF denominator includes orders already due but still undelivered.
- [ ] Live total score remains unavailable until delivery, production, and evaluated decision evidence exist.
- [ ] Teacher can evaluate decisions with a score and feedback; individual ranking uses evaluated scores.
- [ ] Round snapshots use the current round and are reproducible from saved operational records.
- [ ] Finalisation is blocked before the last round.
- [ ] Finalisation records a zero score for teams with insufficient evidence and locks the competition.
- [ ] Students can see the final team podium and top decision-makers.

## 5. Mobile and recovery

- [ ] Test at 320, 360, 390, and 430 px widths.
- [ ] No horizontal page overflow; forms and team cards remain readable.
- [ ] Refresh and sign-out/sign-in preserve all submitted records and competition state.
- [ ] Empty states, paused state, completed state, network errors, and permission errors are understandable.
- [ ] Verify a second teacher cannot access another teacher's classroom competition.

## Current verification boundary

Database migrations, role-checked RPC definitions, RLS policies, view definitions, HTML element references, JavaScript syntax validation, and Cloudflare deployment have been checked. A full authenticated teacher-plus-20-student browser test still needs to be run against real test accounts.
