# Amazon Global Combined Crisis — Case Specification

> Status: design baseline for implementation and classroom QA.
> This is a fictional educational simulation inspired by e-commerce fulfilment operations. It is not an official Amazon case, supplier contract, or representation of Amazon's internal data. All quantities, prices, capacities, service levels, and constraints below are synthetic.

## 1. Simulation brief

Amazon Global Combined Crisis places one global e-commerce fulfilment network under simultaneous demand and supply shocks. Teams must protect customer service while controlling procurement spend, inventory exposure, fulfilment throughput, and transport cost.

- Simulation horizon: 30 virtual days.
- Play time: 30 real minutes.
- Model: three sequential rounds, with decisions submitted in each round and resolved together.
- Difficulty: realistic.
- Market: one unified global market.
- Assortment: five SKUs.
- Demand shock: +40% versus normal 30-day demand.
- Main supplier disruption: China Supplier A receives a +10-day delay.
- Supplier model: three global suppliers (A China, B Germany, C USA), with supplier relationship negotiation.
- Budget: $160,000 main procurement budget plus a $30,000 emergency reserve. The reserve is only available after the required team approval.
- Teams begin from identical conditions. No random initial advantages.

## 2. Roles and database mapping

Student-facing roles (exact labels):
1. Procurement Manager — database role `procurement`.
2. Supplier Relations Manager — database role `supplier`.
3. Fulfillment Operations Manager — database role `manufacturer` (legacy database identifier retained; student-facing label must not say Manufacturer).
4. Warehouse Manager — database role `warehouse`.
5. Transport Manager — database role `transport`.

Each role has an independent decision domain. Decisions that materially affect another role's capacity, inventory, delivery promise, or cost require cross-role coordination. The role assignment and RLS model must remain team-scoped.

## 3. Round structure

### Round 1 — Stabilise and plan (Days 1–10)
- Demand has risen 40%; opening inventory and supplier offers are visible.
- Procurement submits the initial SKU-by-SKU sourcing plan.
- Supplier Relations validates supplier commitments and negotiates terms within allowed bounds.
- Fulfillment Operations reserves pick/pack/dispatch capacity and prioritises high-risk SKUs.
- Warehouse plans receiving, storage, labour, and slotting under reduced capacity.
- Transport chooses service mix, lane capacity, and carrier commitments.
- Round 1 is not complete until all five roles have submitted their decisions or the teacher closes the round.

### Round 2 — Supplier disruption (Days 11–20)
- Supplier A's lead time is increased by 10 days (12 to 22 days).
- The system exposes the delayed purchase orders and SKU-level projected shortages.
- Procurement may source from B/C or request emergency reserve approval.
- Supplier Relations may negotiate revised delivery commitments, partial shipments, or approved alternatives.
- Fulfillment Operations reallocates constrained throughput to the highest-value / highest-service-risk SKUs.
- Warehouse manages inbound congestion, reduced usable capacity, and prioritised put-away.
- Transport rebalances inbound/outbound capacity and expedited lanes.
- A strategic procurement model change requires the approval workflow below.

### Round 3 — Recover and optimise (Days 21–30)
- New orders must arrive within the remaining horizon to contribute to available stock.
- Teams prioritise open demand, clear backlogs, and avoid ending with excessive slow-moving stock.
- Existing in-transit orders can still be received/delivered when their simulated ETA falls inside the horizon.
- No new action may create an ETA beyond Day 30.
- Final score and financial report use actual resolved transactions, not a pre-filled result.

## 4. Demand and opening stock

| SKU | Product | Normal demand | Crisis demand (+40%) | Opening stock | Net supply gap |
|---|---|---:|---:|---:|---:|
| SKU-01 | Wireless Earbuds | 2,000 | 2,800 | 500 | 2,300 |
| SKU-02 | Wireless Mouse | 2,500 | 3,500 | 700 | 2,800 |
| SKU-03 | Smart Watch | 1,200 | 1,680 | 300 | 1,380 |
| SKU-04 | Coffee Maker | 800 | 1,120 | 200 | 920 |
| SKU-05 | Ergonomic Office Chair | 500 | 700 | 150 | 550 |
| **Total** | | **7,000** | **9,800** | **1,850** | **7,950** |

Demand is the team's total 30-day customer demand. It must be released in round-sized tranches while preserving the same aggregate demand for every team. Unserved demand remains visible as backlog/lost service; it must not silently disappear at round boundaries.

## 5. Supplier offers

All figures are synthetic. Price is USD per unit.

| Supplier | Region | Price index | Normal lead time | OTIF baseline | Defect rate | Crisis rule |
|---|---|---:|---:|---:|---:|---|
| A | China | 100 | 12 days | 90% | 2.5% | +10-day disruption; crisis lead time 22 days |
| B | Germany | 115 | 8 days | 96% | 1.0% | No imposed delay |
| C | USA | 125 | 5 days | 98% | 0.5% | No imposed delay |

### Unit prices

| Product | A China | B Germany | C USA |
|---|---:|---:|---:|
| Wireless Earbuds | $12.00 | $13.80 | $15.00 |
| Wireless Mouse | $8.00 | $9.20 | $10.00 |
| Smart Watch | $28.00 | $32.20 | $35.00 |
| Coffee Maker | $35.00 | $40.25 | $43.75 |
| Ergonomic Office Chair | $48.00 | $55.20 | $60.00 |

### Minimum order quantities

| Product | A China | B Germany | C USA |
|---|---:|---:|---:|
| Wireless Earbuds | 100 | 50 | 25 |
| Wireless Mouse | 100 | 50 | 25 |
| Smart Watch | 50 | 25 | 20 |
| Coffee Maker | 25 | 20 | 10 |
| Ergonomic Office Chair | 10 | 10 | 5 |

### Maximum 30-day order capacity by supplier and SKU

| Product | A China | B Germany | C USA |
|---|---:|---:|---:|
| Wireless Earbuds | 2,500 | 700 | 500 |
| Wireless Mouse | 3,000 | 800 | 600 |
| Smart Watch | 1,400 | 400 | 300 |
| Coffee Maker | 900 | 250 | 200 |
| Ergonomic Office Chair | 550 | 150 | 100 |

Capacity is cumulative across the full simulation horizon and must be enforced per supplier and SKU. Supplier A's Coffee Maker capacity is 20 units below the net gap, so at least 20 units must come from B or C even in a cost-led feasible plan.

### Procurement cost sanity check

The cheapest feasible baseline buys as much as possible from A, then uses B for the 20 Coffee Maker units A cannot supply. Its cost is $147,345 before any freight, duties, holding, or other operating costs. This is a planning benchmark, not a guaranteed optimal plan under timing, storage, or service constraints. The $160,000 main budget therefore leaves limited headroom; students must consider landed/operating costs and cannot treat the budget as a target to exhaust.

## 6. Procurement Manager — confirmed policy

### Mission
Maintain supply continuity across all five SKUs while controlling total procurement cost, avoiding stockouts and preventing excess inventory.

### Authority
- Independently select suppliers and place orders within the approved strategy limits, MOQ, supplier capacity, lead-time horizon, and $160,000 main budget.
- Submit a request for the $30,000 emergency reserve; it is unavailable until approved.
- Orders exceeding the main budget, changing the approved strategic posture, or materially affecting other roles require team approval.
- Submit a hybrid plan: strategic posture first, then SKU-level supplier allocation, order quantities, and planned order dates.

### Strategic sourcing posture — Limits model
Selecting a posture creates enforceable supplier-mix limits across total ordered units:
- Cost-focused: at least 60% of total ordered units from Supplier A.
- Balanced: Supplier A must represent 40–70% of total ordered units.
- Service-focused: at least 60% of total ordered units from Suppliers B and C combined.

**Feasibility check:** B+C combined maximum capacity is 4,000 units against a 7,950-unit net replenishment gap (50.3%). Therefore the 60% Service-focused posture is infeasible under the agreed supplier capacity table and is disabled in the live UI. Cost-focused and Balanced remain selectable. A feasible Balanced mix at the 70% A limit can source 5,565 units from A, 2,300 from B and 85 from C for an estimated $153,702.50 procurement cost before freight/holding. This is a planning baseline; the timing and storage constraints still apply.

The selected posture does not waive SKU-specific MOQ, supplier capacity, supplier lead time, budget, or storage limits. The system validates the actual order mix; it must not score an invalid plan as compliant.

### Strategic posture change — Approval-based
A manager submits a change request with a written reason. The request passes only when:
- at least 3 of the 5 team members approve; and
- every role materially affected by the change also approves (for procurement, this normally includes Warehouse, Fulfillment Operations, and/or Transport when the change alters inbound volume, receiving peaks, fulfilment availability, or transport requirements).

If rejected, the prior posture remains in force. Approval history, approvers, reason, old posture, and new posture must be auditable.

### Round 1 plan submission — Hybrid
1. Choose Cost-focused, Balanced, or Service-focused.
2. Submit SKU-level quantities, supplier allocations, and order day.
3. System validates supplier mix, MOQ, SKU capacity, budget, arrival within Day 30, and warehouse constraints.
4. Cross-role approvals are requested for exceptions or material operational impacts.
5. Approved purchase orders become operationally effective and consume supplier capacity/budget.

### Procurement KPIs (individual)
- Purchase cost efficiency against the lowest feasible cost under the same delivery and capacity constraints.
- Demand coverage: share of the 7,950-unit net supply gap covered by valid, horizon-feasible orders.
- On-time supply availability: ordered units available by their required demand dates.
- Plan accuracy: difference between planned and actual received quantities/timing.
- Compliance: adherence to strategic limits, MOQ, supplier capacity, budget, and approval rules.

The role score must be calculated from actual outcomes and constraints, not merely from which strategy the student selected. The team score remains based on the existing shared weighted scorecard unless a versioned case-specific rubric is added.

## 7. Other role decision domains

### Fulfilment throughput implementation parameter
- Fulfillment Operations release capacity is 4,000 units per round, enforced by the backend. This is intentionally above the largest round demand tranche so teams can recover backlog when inventory is available; actual output remains constrained by received inventory, SKU reservations, warehouse capacity, and outbound carrier capacity.


### Supplier Relations Manager
- Own supplier communication, commitment confirmation, negotiation, escalation, and supplier risk monitoring.
- May propose changes to lead time, price, reliability, partial delivery, and recovery commitments only within server-enforced negotiation bounds.
- Cannot unilaterally alter Procurement's approved supplier allocation or exceed supplier capacity.
- Must communicate the consequences of any negotiated term change to Procurement and affected Warehouse/Transport roles.
- Round outputs: confirmed supplier commitments, revised ETAs, risk register, and recovery recommendation.

### Fulfillment Operations Manager
- Student-facing name replaces legacy Manufacturer label; no manufacturing of the five finished consumer products is implied.
- Own fulfilment throughput: receiving-to-available handoff coordination, pick/pack capacity, order prioritisation, wave planning, and backlog recovery.
- Must not create inventory or production out of thin air. Available-to-promise stock is limited by received inventory, warehouse availability, and fulfilment throughput.
- Round outputs: SKU priority, fulfilment capacity allocation, order release plan, and backlog recovery plan.

### Warehouse Manager
- Own inbound receiving, put-away, storage capacity, inventory accuracy, replenishment, and pick-face availability.
- Must validate purchase-order receipts against actual availability date and ordered quantity.
- Usable storage capacity is reduced during the crisis. The case design baseline uses a 20% reduction as a provisional implementation default; this value must be clearly surfaced to the teacher and can be tuned before classroom launch.
- Round outputs: receiving schedule, slotting/capacity allocation, safety-stock policy, and exception handling.

### Transport Manager
- Own inbound and outbound carrier allocation, lane capacity, delivery speed/cost trade-offs, dispatch, tracking, and delivery confirmation.
- Economy/standard/express decisions trade off transit time against per-unit transport cost.
- Cannot dispatch more than fulfilment-released, warehouse-available inventory or exceed customer order quantities.
- Round outputs: lane/carrier plan, mode split, dispatch priorities, and ETA recovery.

## 8. Team approval workflow

- Each member votes once per request; requester cannot self-approve.
- Approval threshold: 3 of 5 team members.
- Every materially affected role must also approve, even if the 3-vote threshold is met.
- Emergency reserve draw, strategic posture change, and major cross-functional exceptions use this workflow.
- Requests expire when the round closes; pending requests do not silently apply.
- All decisions and votes are immutable audit events. A rejected request leaves the prior operational state unchanged.

## 9. Scoring

Existing team score weights are preserved:
- Service: 25%.
- Cost: 20%.
- Inventory health: 15%.
- Lead time: 15%.
- Productivity: 10%.
- Decision quality: 15%.

Case-specific individual role scoring must be separately calculated and explained. No role should receive full credit for a choice alone; the engine evaluates constraints, actual operational result, rationale quality, and cross-role coordination. Missing evidence is marked as missing/low coverage, not fabricated.

Anti-gaming requirements:
- Orders arriving after Day 30 do not count as available supply.
- Supplier capacity is cumulative by SKU across all rounds.
- MOQ applies to each purchase order unless the supplier contract explicitly allows consolidation.
- Duplicate or cancelled orders do not count toward demand coverage.
- Unreceived purchase orders do not count as available inventory.
- Customer demand and opening stock are identical across teams.
- End-of-horizon inventory carries holding/obsolescence cost; stockouts/backlog reduce service.
- Approval votes and operational events must be team-scoped and auditable.

## 10. Final report

For each team, show:
- demand by SKU, fulfilled units, unserved/backlog units, and service level;
- supplier spend by supplier and SKU, valid orders, receipts, and late orders;
- inbound and outbound transport cost and on-time delivery;
- opening, received, dispatched, and closing inventory by SKU;
- warehouse capacity utilisation and fulfilment throughput;
- revenue, recorded operating costs, operating profit, margin, and cash balance;
- team score, component scores, score coverage, and individual role contribution;
- decision log and approval audit trail.

All financial figures must reconcile to the transaction ledger. Do not label a simplified educational contribution as audited profit. Display the simulation disclaimer prominently.

## 11. Implementation acceptance tests

1. Create a new Amazon Global Combined Crisis competition without editing the two existing draft competitions.
2. All teams receive identical opening inventory, demand, supplier offers, capacities, and crisis events.
3. Exactly five student-facing roles are offered and assignable.
4. The 30-day horizon advances in three 10-day rounds.
5. Supplier A lead time is 22 days during the crisis; B and C remain 8 and 5 days respectively.
6. All 5 SKU demand, opening inventory, price, MOQ, and supplier capacity values match this spec.
7. Procurement strategic mix validation rejects invalid plans.
8. Procurement posture change and emergency reserve draw require the defined approval workflow.
9. Cross-role capacity and inventory constraints prevent impossible operations.
10. No purchase order or shipment can contribute to service if its availability/ETA is after Day 30.
11. Final report reconciles to saved orders, receipts, shipments, revenue, and costs.
12. Generic exam/scenario modules and other company templates remain unchanged.
13. Mobile layout is usable at narrow Android viewport widths.
14. RLS and role checks prevent a student from reading or changing another team's operational records.
15. A successful deployment is not treated as classroom QA until teacher and student accounts complete an end-to-end test.
