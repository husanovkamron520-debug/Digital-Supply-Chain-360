# SupplyChain14 — Classroom QA Checklist

Use this checklist on a real phone before using the platform with a full class. Use test accounts and test data; do not use personal or production business information.

## 1. Teacher account
- [ ] Sign up and sign in.
- [ ] Create a classroom with a recognizable class name.
- [ ] Copy the join code.
- [ ] Add a student test account to the classroom.
- [ ] Assign and change the student's operational role.
- [ ] Confirm the student cannot assign their own role or promote their platform role.

## 2. Student account
- [ ] Join the classroom with the correct code.
- [ ] Refresh the page and confirm the classroom membership remains.
- [ ] Confirm the assigned role appears correctly.
- [ ] Confirm navigation and available actions match the assigned role.

## 3. Procurement and supplier workflow
- [ ] Assign a test account the Supplier role.
- [ ] Supplier creates its linked supplier profile.
- [ ] Assign a Manufacturer and create a purchase order for that supplier.
- [ ] Supplier sees only its own supplier profile and purchase orders.
- [ ] Supplier accepts one purchase order.
- [ ] Supplier rejects a second purchase order.
- [ ] Assign Warehouse role.
- [ ] Warehouse receives part of the accepted order.
- [ ] Confirm inventory increases by exactly the received quantity.
- [ ] Confirm warehouse cannot receive the rejected order.
- [ ] Confirm a linked supplier's pending order cannot be received by warehouse.
- [ ] Confirm a supplier cannot accept/reject another supplier's order.

## 4. Inventory and operations
- [ ] Create an inventory item.
- [ ] Receive stock and confirm quantity increases.
- [ ] Issue stock and confirm quantity decreases.
- [ ] Create an order and test valid status transitions.
- [ ] Create a shipment and test valid status transitions.
- [ ] Confirm invalid transitions are rejected by the database.
- [ ] Confirm activity history records successful changes.

## 5. Scenario Simulation Lab
- [ ] Teacher launches Supplier Delay.
- [ ] Student submits one decision and rationale.
- [ ] Teacher reviews results and completes the scenario.
- [ ] Repeat with Demand Spike and Route Disruption.
- [ ] Confirm scenario-tagged records do not alter baseline operational inventory, orders, or shipments.

## 6. Teacher analytics
- [ ] Select the correct classroom.
- [ ] Confirm operational order, shipment, inventory, and participation counts.
- [ ] Confirm scenario data is not counted as baseline operations.

## 7. Mobile and session checks
- [ ] Test portrait and landscape orientations.
- [ ] Test the smallest available phone viewport.
- [ ] Check that forms, buttons, tables/cards, and navigation do not overflow horizontally.
- [ ] Refresh each workspace and confirm it still loads.
- [ ] Sign out and sign back in.
- [ ] Check loading, empty, success, and error messages.

## Release decision

Do not call the platform classroom-ready until the critical teacher/student/supplier/warehouse flows pass on a real phone. A green GitHub Actions run only confirms syntax validation and Cloudflare deployment.

## 8. Automated backend checks (2026-11-14)

The following checks were executed against the Supabase project using test identities and rolled-back transactions. They do not replace the real-phone checks above.

- [x] Supplier can create its own supplier record and respond to its own purchase order.
- [x] Manufacturer can create purchase orders but cannot receive them.
- [x] Warehouse can receive an accepted linked-supplier purchase order but cannot create purchase orders or receive a pending linked-supplier order.
- [x] Supplier cannot respond to another supplier's purchase order.
- [x] Transport can create and update shipments but cannot create customer orders or change order status.
- [x] Customer can create an order.
- [x] Student cannot launch a scenario; teacher can launch one.
- [x] Student cannot change their own operational role or platform role; teacher can assign an operational role.
- [x] Student can read their own profile and membership, but not the teacher's profile or membership.
- [x] QA records were rolled back; no test data was retained.

## 9. Role-based navigation

- [ ] Teacher sees Operations, Procurement, and Teacher Analytics.
- [ ] Supplier, Manufacturer, and Warehouse see Procurement.
- [ ] Customer, Retailer, and Transport see Orders & Shipments.
- [ ] Student with no operational role does not see operational workspaces.
- [ ] Confirm each menu item on both desktop and mobile after sign-in and after role changes.
