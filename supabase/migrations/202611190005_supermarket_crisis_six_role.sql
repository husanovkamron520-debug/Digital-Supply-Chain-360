-- Supermarket Crisis: simple, realistic 7-day case with six coordinated roles.
-- Synthetic educational data only; no official supermarket data is represented.

insert into public.company_templates
(slug,name,industry,business_model,operating_profile,scoring_weights,active,case_study_note,source_urls)
values
('supermarket-crisis-7day','Supermarket Crisis','Grocery retail and distribution',
 'Three-branch supermarket network balancing replenishment, supplier reliability, store demand, warehouse capacity and last-mile delivery.',
 '{"product_name":"Everyday grocery basket","raw_material_name":"Store-ready grocery stock","capital_index":30000,"initial_raw_units":1800,"initial_finished_units":0,"raw_reorder_level":450,"finished_reorder_level":0,"target_cost_per_unit":4.5,"raw_material_unit_cost":4.5,"selling_price":8.5,"supplier_count":3,"supplier_a_days":2,"supplier_b_days":3,"supplier_c_days":1,"baseline_lead_time_days":2,"transport_cost_per_unit":0.58,"capacity_units_per_round":1800,"conversion_cost_per_unit":0,"safety_stock_days":1.5,"holding_cost_rate":0.006,"demand_volatility":"medium","warehouse_capacity_units":2400,"demand_shock_pct":35,"round_count":3,"horizon_days":7}',
 '{"service":25,"cost":20,"inventory":15,"lead_time":15,"productivity":10,"decision_quality":15}',
 true,
 'Educational supermarket supply-chain case based on common grocery retail operations. All prices, quantities, suppliers, capacities and service levels are synthetic and are not data from a named supermarket.',
 '["https://www.gs1.org/standards/traceability","https://www.fao.org/food-loss-and-food-waste/en/"]'::jsonb)
on conflict (slug) do update set name=excluded.name,industry=excluded.industry,business_model=excluded.business_model,
 operating_profile=excluded.operating_profile,scoring_weights=excluded.scoring_weights,active=true,
 case_study_note=excluded.case_study_note,source_urls=excluded.source_urls;

create or replace function public.create_balanced_competition_teams(p_competition_id uuid,p_team_count integer default 4)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
 v_classroom_id uuid; v_status text; v_student_count integer; v_created integer:=0;
 v_member record; v_team_ids uuid[]:='{}'::uuid[]; v_team_names text[]:='{}'::text[];
 v_template record; v_team_id uuid; v_team_no integer; v_role_no integer;
 v_roles text[]; v_required integer; v_idx integer:=0; v_student_assignments integer:=0;
 v_case_code text; v_company_name text;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if p_team_count is null or p_team_count not between 2 and 4 then raise exception 'Choose between 2 and 4 teams'; end if;
 select classroom_id,status,settings->>'case_code' into v_classroom_id,v_status,v_case_code
 from public.competitions where id=p_competition_id for update;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create teams'; end if;
 if v_status<>'draft' then raise exception 'Competition must be in draft'; end if;
 if exists(select 1 from public.competition_teams where competition_id=p_competition_id) then raise exception 'Teams already exist; use manual assignment instead'; end if;
 if v_case_code='supermarket-crisis-7day' then
  v_roles:=array['procurement','supplier','manufacturer','warehouse','transport','retailer']; v_required:=6; v_company_name:='Supermarket';
 else
  v_roles:=array['procurement','supplier','manufacturer','warehouse','transport']; v_required:=5; v_company_name:='Amazon';
 end if;
 select count(*) into v_student_count from public.classroom_members where classroom_id=v_classroom_id;
 if v_case_code='supermarket-crisis-7day' and v_student_count<>p_team_count*v_required then raise exception 'Supermarket case requires exactly % students for % teams of six',p_team_count*v_required,p_team_count; end if;
 if v_student_count<p_team_count*v_required then raise exception 'At least % students are required for % teams with % roles each',p_team_count*v_required,p_team_count,v_required; end if;
 select id,name into v_template from public.company_templates
 where slug=case when v_case_code='amazon-global-combined-crisis' then 'amazon-global-combined-crisis'
  when v_case_code='supermarket-crisis-7day' then 'supermarket-crisis-7day' else 'omnichannel-retail' end and active;
 if not found then raise exception 'The selected active company template is missing'; end if;
 for v_team_no in 1..p_team_count loop
  v_created:=v_created+1;
  insert into public.competition_teams(competition_id,classroom_id,company_template_id,name)
  values(p_competition_id,v_classroom_id,v_template.id,v_company_name||' · Team '||v_created) returning id into v_team_id;
  v_team_ids:=array_append(v_team_ids,v_team_id); v_team_names:=array_append(v_team_names,v_company_name||' · Team '||v_created);
 end loop;
 for v_member in select student_id,row_number() over(order by joined_at,student_id)::integer as rn
  from public.classroom_members where classroom_id=v_classroom_id order by joined_at,student_id
 loop
  v_idx:=v_member.rn; v_team_no:=((v_idx-1)%p_team_count)+1;
  v_role_no:=(((v_idx-1)/p_team_count)%array_length(v_roles,1))+1;
  insert into public.competition_team_members(competition_id,team_id,classroom_id,student_id,operational_role)
  values(p_competition_id,v_team_ids[v_team_no],v_classroom_id,v_member.student_id,v_roles[v_role_no]);
  v_student_assignments:=v_student_assignments+1;
 end loop;
 if v_case_code='amazon-global-combined-crisis' then
  foreach v_team_id in array v_team_ids loop perform public.amazon_initialize_team(v_team_id); end loop;
 end if;
 return jsonb_build_object('competition_id',p_competition_id,'team_count',v_created,'student_count',v_student_assignments,
  'company',v_company_name,'team_names',to_jsonb(v_team_names),'students_per_team',v_required);
end;$function$;

create or replace function public.create_supermarket_role_tasks(p_competition_id uuid)
returns integer language plpgsql security definer set search_path=''
as $function$
declare v_classroom_id uuid; v_status text; v_team record; v_count integer:=0; v_inserted integer;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id,status into v_classroom_id,v_status from public.competitions where id=p_competition_id;
 if not found then raise exception 'Competition not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can create case tasks'; end if;
 if v_status not in ('draft','active') then raise exception 'Competition is not accepting tasks'; end if;
 if exists(select 1 from public.competition_tasks where competition_id=p_competition_id) then raise exception 'Tasks already exist. Do not duplicate the case pack'; end if;
 for v_team in select id,name from public.competition_teams where competition_id=p_competition_id loop
  if (select count(distinct operational_role) from public.competition_team_members
   where competition_id=p_competition_id and team_id=v_team.id
   and operational_role in ('procurement','supplier','manufacturer','warehouse','transport','retailer'))<>6
   then raise exception 'Every team must have all six roles before case tasks are generated'; end if;
  insert into public.competition_tasks
   (competition_id,team_id,classroom_id,assigned_to,assigned_role,title,description,priority,due_round,created_by)
  select p_competition_id,v_team.id,v_classroom_id,m.student_id,x.role,x.title,x.description,x.priority,x.due_round,(select auth.uid())
  from (values
   ('procurement'::text,'Procurement Manager · Xarid rejasi','7 kunlik talab 3,000 dona; talab +35%. Supplier A: $4.50, 2 kun, 96% OTIF, MOQ 200. B: $4.20, 4 kun, 91%, MOQ 400. C: $4.85, 1 kun, 99%, MOQ 150. Budjet $30,000, favqulodda zaxira $5,000. Talabni hisoblang, supplierlarni jami xarajat va yetkazish xavfi bo‘yicha solishtiring, xarid miqdori va zaxira supplierni tanlang. Hisob-kitob va jadval ko‘rsating.','critical',1),
   ('supplier','Supplier Relations Manager · Muzokara','A supplier 2 kun kechikadi. A 3% chegirma taklif qiladi, lekin MOQ 200 dan 500 ga oshadi. C tezroq, lekin qimmatroq. OTIF, sifat, kechikish xabari va kompensatsiya bo‘yicha SLA taklif qiling; qachon alternativ supplierga o‘tishni belgilang. Procurementga muzokara xulosasini yuboring.','high',1),
   ('manufacturer','Fulfillment Operations Manager · Buyurtmalarni tayyorlash','Uch filialdan jami 4,050 dona buyurtma keldi. Kunlik quvvat 650 dona, 2% sifat nuqsoni. 4,050 yaroqli dona uchun yalpi qancha tayyorlash kerak? 7 kunlik jadval, filiallar ustuvorligi va sifat nazorat nuqtasini belgilang. Ombor va Transport bilan kelishing.','critical',2),
   ('warehouse','Warehouse Manager · Zaxira va sifat','Omborda 1,800 dona; 120 dona karantinda; 900 dona filiallar uchun ajratilgan; sig‘im 2,400. Supplier 700 dona ertaga yoki 1,000 dona 3 kundan keyin yetkazadi. Available stock, qabul jadvali, FIFO/FEFO va sig‘imdan oshmaslik rejasini hisoblang. Procurementga xabar bering.','critical',2),
   ('transport','Transport Manager · Marshrut','Birinchi jo‘natish to‘lqini: Markaz 900 dona (2 kunda), Yangiobod 700 dona (4 kunda), Siyob 600 dona (5 kunda); qolgan 1,850 dona keyingi to‘lqinda yuboriladi. Mashina sig‘imi 1,000. Economy $0.42/dona, 4 kun; Standard $0.58, 2 kun; Express $0.91, 1 kun. Kechikkan dona uchun xizmat jarimasi $1.20. Reys, xizmat darajasi, xarajat va ETA rejasini tuzing.','high',3),
   ('retailer','Store & Demand Manager · Filiallar talabi','So‘nggi 7 kunlik savdo: Markaz 1,200, Yangiobod 1,000, Siyob 800 dona (jami 3,000). Talab +35% bo‘lsa jami prognoz 4,050 dona. Har filial uchun yangi talabni hisoblang, mavjud zaxirani taqsimlang, qaysi filialga ustuvorlik berishni asoslang va Procurement, Warehouse, Transport bilan kelishing.','critical',1)
  ) as x(role,title,description,priority,due_round)
  join public.competition_team_members m on m.competition_id=p_competition_id and m.team_id=v_team.id and m.operational_role=x.role;
  get diagnostics v_inserted=row_count;
  if v_inserted<>6 then raise exception 'Every member must receive exactly one of six role tasks'; end if;
  v_count:=v_count+v_inserted;
 end loop;
 return v_count;
end;$function$;

revoke all on function public.create_supermarket_role_tasks(uuid) from public,anon;
grant execute on function public.create_supermarket_role_tasks(uuid) to authenticated;
