-- Public-source company case profiles for the educational competition engine.
-- All numeric values below are synthetic teaching parameters, not company data.
alter table public.company_templates
 add column if not exists case_study_note text not null default 'Educational case study based on public information. All simulation quantities, prices, capacities and service targets are synthetic, not official company data.',
 add column if not exists source_urls jsonb not null default '[]'::jsonb;
alter table public.company_templates drop constraint if exists company_templates_source_urls_array_check;
alter table public.company_templates add constraint company_templates_source_urls_array_check check(jsonb_typeof(source_urls)='array');

update public.company_templates set
 name='Toyota',industry='Automotive manufacturing',
 business_model='Lean automotive production: Just-in-Time flow, synchronized suppliers, Jidoka quality controls and continuous Kaizen.',
 operating_profile='{"capacity_units_per_round":1200,"baseline_lead_time_days":7,"safety_stock_days":3,"supplier_count":3,"demand_volatility":"medium","capital_index":100,"constraints":["just_in_time","line_balance","jidoka_quality","supplier_synchronization"],"raw_material_unit_cost":8.5,"conversion_cost_per_unit":4,"initial_raw_units":420,"initial_finished_units":70,"raw_reorder_level":180,"finished_reorder_level":35,"supplier_a_days":3,"supplier_b_days":7,"supplier_c_days":12,"selling_price":55,"product_name":"Automotive components","raw_material_name":"Precision components"}'::jsonb,
 scoring_weights='{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb,
 case_study_note='Educational Toyota Production System case: JIT synchronisation, Jidoka quality response and Kaizen. Numeric capacities, costs, stock levels and lead times in this simulation are synthetic, not Toyota operating data.',
 source_urls='["https://global.toyota/en/company/vision-and-philosophy/production-system/index.html"]'::jsonb,active=true
where slug='lean-automotive';

update public.company_templates set
 name='Amazon',industry='E-commerce and fulfilment logistics',
 business_model='Third-party seller and FBA-style fulfilment network: demand forecasting, distributed inventory positioning, automated fulfilment and last-mile delivery.',
 operating_profile='{"capacity_units_per_round":1500,"baseline_lead_time_days":3,"safety_stock_days":5,"supplier_count":5,"demand_volatility":"high","capital_index":100,"constraints":["demand_forecasting","distributed_inventory","fulfillment_capacity","last_mile"],"raw_material_unit_cost":7.2,"conversion_cost_per_unit":2,"initial_raw_units":650,"initial_finished_units":180,"raw_reorder_level":300,"finished_reorder_level":90,"supplier_a_days":2,"supplier_b_days":4,"supplier_c_days":7,"selling_price":30,"product_name":"Fulfilled consumer goods","raw_material_name":"Merchant inventory"}'::jsonb,
 scoring_weights='{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb,
 case_study_note='Educational Amazon marketplace/FBA-style case focused on inventory positioning, fulfilment and delivery. The manufacturer role represents the seller or upstream production partner. Numeric simulation values are synthetic, not Amazon internal data.',
 source_urls='["https://www.aboutamazon.com/news/small-business/supply-chain-by-amazon","https://www.aboutamazon.com/news/operations/amazon-robotics-robots-fulfillment-center"]'::jsonb,active=true
where slug='omnichannel-retail';

update public.company_templates set
 name='IKEA',industry='Furniture retail and global sourcing',
 business_model='Global furniture sourcing and supplier partnerships, flat-pack design, cost-led product development and efficient distribution.',
 operating_profile='{"capacity_units_per_round":1000,"baseline_lead_time_days":14,"safety_stock_days":7,"supplier_count":4,"demand_volatility":"medium","capital_index":100,"constraints":["flat_pack_design","container_utilisation","global_sourcing","sustainability"],"raw_material_unit_cost":10,"conversion_cost_per_unit":3.5,"initial_raw_units":500,"initial_finished_units":100,"raw_reorder_level":250,"finished_reorder_level":60,"supplier_a_days":8,"supplier_b_days":14,"supplier_c_days":22,"selling_price":65,"product_name":"Flat-pack furniture","raw_material_name":"Furniture components"}'::jsonb,
 scoring_weights='{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb,
 case_study_note='Educational IKEA value-chain case focused on design-to-cost, global sourcing, flat-pack logistics, supplier partnerships and sustainability. Numeric simulation values are synthetic, not IKEA operating data.',
 source_urls='["https://www.ikea.com/global/en/our-business/how-we-work/the-ikea-value-chain/","https://www.ikea.com/global/en/our-business/our-view-on/transport-and-logistics/"]'::jsonb,active=true
where slug='flatpack-global';

update public.company_templates set
 name='Coca-Cola',industry='Beverage production and distribution',
 business_model='Concentrate and syrup production coordinated with local bottling partners, local ingredient and packaging supply, high-volume bottling and regional distribution.',
 operating_profile='{"capacity_units_per_round":1800,"baseline_lead_time_days":4,"safety_stock_days":4,"supplier_count":4,"demand_volatility":"high","capital_index":100,"constraints":["shelf_life","local_bottling_partners","packaging_supply","route_efficiency"],"raw_material_unit_cost":4.5,"conversion_cost_per_unit":2.5,"initial_raw_units":700,"initial_finished_units":200,"raw_reorder_level":300,"finished_reorder_level":100,"supplier_a_days":2,"supplier_b_days":4,"supplier_c_days":8,"selling_price":20,"product_name":"Packaged beverages","raw_material_name":"Beverage ingredients and packaging"}'::jsonb,
 scoring_weights='{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}'::jsonb,
 case_study_note='Educational Coca-Cola system case focused on concentrate production, independent local bottling partners, local sourcing and regional distribution. Numeric simulation values are synthetic, not official company data.',
 source_urls='["https://www.coca-colacompany.com/about-us/coca-cola-system","https://www.coca-colacompany.com/media-center/how-the-coca-cola-system-refreshes-local-economies-and-communities-in-markets-around-the-world"]'::jsonb,active=true
where slug='beverage-fast-moving';
