
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_create_role_tasks(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  'Supplier A/B/C have SKU-specific MOQ, capacity and prices shown in the live case panel.',
  'Supplier A/B/C have SKU-specific MOQ, capacity and prices shown in the live case panel; OTIF assumptions are 90/96/98% and defect rates are 2.5/1/0.5% respectively.');
 v_def:=replace(v_def,
  'Receive purchase orders only at their virtual ETA; validate SKU and quantity, update available stock, and coordinate release reservations with Fulfillment.',
  'Receive purchase orders only at their virtual ETA; inspect supplier quality, quarantine defective units, record disposal/return, update usable stock and coordinate release reservations with Fulfillment.');
 v_def:=replace(v_def,
  'Outbound standard transit is two virtual days at the synthetic $2.50/unit benchmark.',
  'Choose Economy ($1.75/unit, 3 days, 2,500 units/round), Standard ($2.50/unit, 2 days, 2,200 units/round) or Express ($4.25/unit, 1 day, 1,000 units/round).');
 execute v_def;
end $migration$;
