
update public.company_templates
set operating_profile=operating_profile || jsonb_build_object(
 'raw_material_unit_cost',8,
 'conversion_cost_per_unit',2,
 'initial_raw_units',500,
 'initial_finished_units',100,
 'raw_reorder_level',200,
 'finished_reorder_level',60
)
where slug='amazon-global-combined-crisis';
