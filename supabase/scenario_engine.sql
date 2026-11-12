-- SupplyChain14 scenario decision engine (idempotent migration)
create table if not exists public.scenario_decisions (
 id uuid primary key default gen_random_uuid(),
 scenario_id uuid not null references public.scenarios(id) on delete cascade,
 classroom_id uuid not null references public.classrooms(id) on delete cascade,
 student_id uuid not null references public.profiles(id) on delete cascade,
 selected_action text not null check(char_length(selected_action) between 2 and 60),
 rationale text not null default '' check(char_length(rationale)<=1000),
 score integer not null check(score between 0 and 100),
 feedback text not null,
 submitted_at timestamptz not null default now(),
 unique(scenario_id,student_id)
);
create index if not exists scenario_decisions_classroom_idx on public.scenario_decisions(classroom_id,submitted_at desc);
create index if not exists scenario_decisions_scenario_idx on public.scenario_decisions(scenario_id,score desc);
alter table public.scenario_decisions enable row level security;
drop policy if exists scenario_decisions_select_members on public.scenario_decisions;
create policy scenario_decisions_select_members on public.scenario_decisions for select to authenticated using(public.is_class_member(classroom_id));
revoke all on public.scenario_decisions from public,anon;
revoke insert,update,delete on public.scenario_decisions from authenticated;
grant select on public.scenario_decisions to authenticated;

-- Teacher-only launch. Scenario configuration contains action labels, never scoring weights.
-- The authoritative score is calculated in submit_scenario_decision() on the database.
create or replace function public.launch_supply_scenario(p_classroom_id uuid,p_scenario_type text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_title text; v_config jsonb;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 if not public.is_class_teacher(p_classroom_id) then raise exception 'Only the classroom teacher can launch scenarios'; end if;
 case p_scenario_type
 when 'supplier_delay' then v_title:='Supplier delay — production at risk'; v_config:=jsonb_build_object('type','supplier_delay','severity','high','description','Your main supplier reports a 48-hour delay. Production has only two days of safety stock remaining.','impact','Potential production stoppage and late customer orders.','actions',jsonb_build_array(jsonb_build_object('key','expedite','label','Expedite an alternate supplier'),jsonb_build_object('key','allocate','label','Allocate remaining stock to priority orders'),jsonb_build_object('key','wait','label','Wait for the original supplier')));
 when 'demand_spike' then v_title:='Demand spike — capacity under pressure'; v_config:=jsonb_build_object('type','demand_spike','severity','high','description','Customer demand rises by 35% for the next week, while current production capacity is already 90% utilised.','impact','Overtime cost, service failures, and inventory depletion are possible.','actions',jsonb_build_array(jsonb_build_object('key','prioritise','label','Prioritise orders by service commitment'),jsonb_build_object('key','overtime','label','Add a controlled temporary shift'),jsonb_build_object('key','promise_all','label','Promise every order immediately')));
 when 'route_disruption' then v_title:='Transport disruption — route unavailable'; v_config:=jsonb_build_object('type','route_disruption','severity','critical','description','A key transport corridor is closed for 24 hours. Three customer shipments are waiting at the dispatch hub.','impact','Delivery delays and rising transport costs threaten customer service.','actions',jsonb_build_array(jsonb_build_object('key','reroute','label','Evaluate and dispatch via an alternate route'),jsonb_build_object('key','notify','label','Notify customers and revise delivery promises'),jsonb_build_object('key','dispatch_closed','label','Dispatch through the closed corridor')));
 else raise exception 'Unsupported scenario type'; end case;
 insert into public.scenarios(classroom_id,created_by,title,status,configuration,started_at) values(p_classroom_id,(select auth.uid()),v_title,'active',v_config,now()) returning id into v_id;
 insert into public.activity_logs(classroom_id,scenario_id,actor_id,event_type,description,metadata) values(p_classroom_id,v_id,(select auth.uid()),'scenario_launched',v_title,jsonb_build_object('scenario_type',p_scenario_type));
 return v_id;
end; $$;

create or replace function public.submit_scenario_decision(p_scenario_id uuid,p_action_key text,p_rationale text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_scenario public.scenarios%rowtype; v_action jsonb; v_score integer; v_feedback text; v_uid uuid:=(select auth.uid());
begin
 if v_uid is null then raise exception 'Sign in is required'; end if;
 select * into v_scenario from public.scenarios where id=p_scenario_id for update;
 if not found then raise exception 'Scenario not found'; end if;
 if v_scenario.status<>'active' then raise exception 'This scenario is no longer accepting decisions'; end if;
 if not public.is_class_member(v_scenario.classroom_id) then raise exception 'You are not a member of this classroom'; end if;
 if public.is_class_teacher(v_scenario.classroom_id) then raise exception 'Teachers launch scenarios; students submit decisions'; end if;
 if exists(select 1 from public.scenario_decisions where scenario_id=p_scenario_id and student_id=v_uid) then raise exception 'You have already submitted a decision for this scenario'; end if;
 if char_length(coalesce(p_rationale,''))>1000 then raise exception 'Rationale is too long'; end if;
 select a into v_action from jsonb_array_elements(v_scenario.configuration->'actions') a where a->>'key'=p_action_key limit 1;
 if v_action is null then raise exception 'Invalid action for this scenario'; end if;
 case v_scenario.configuration->>'type'
 when 'supplier_delay' then v_score:=case p_action_key when 'expedite' then 95 when 'allocate' then 82 when 'wait' then 25 else 0 end; v_feedback:=case p_action_key when 'expedite' then 'Strong response: activate a qualified alternate source to protect continuity.' when 'allocate' then 'Good response: prioritisation protects the most important customers while supply is constrained.' else 'High-risk response: waiting leaves production exposed to a stockout.' end;
 when 'demand_spike' then v_score:=case p_action_key when 'prioritise' then 95 when 'overtime' then 84 when 'promise_all' then 20 else 0 end; v_feedback:=case p_action_key when 'prioritise' then 'Strong response: protect service commitments and make capacity trade-offs explicit.' when 'overtime' then 'Good response: additional capacity helps, but cost and fatigue need monitoring.' else 'Risky response: promising beyond capacity creates avoidable service failures.' end;
 when 'route_disruption' then v_score:=case p_action_key when 'reroute' then 95 when 'notify' then 80 when 'dispatch_closed' then 5 else 0 end; v_feedback:=case p_action_key when 'reroute' then 'Strong response: restore flow while checking cost, capacity, and safety.' when 'notify' then 'Responsible response: transparent communication limits customer impact, though freight remains delayed.' else 'Unsafe response: never send shipments through a closed or prohibited route.' end;
 else raise exception 'Unsupported scenario type'; end case;
 insert into public.scenario_decisions(scenario_id,classroom_id,student_id,selected_action,rationale,score,feedback) values(p_scenario_id,v_scenario.classroom_id,v_uid,p_action_key,coalesce(p_rationale,''),v_score,v_feedback);
 insert into public.activity_logs(classroom_id,scenario_id,actor_id,event_type,description,metadata) values(v_scenario.classroom_id,p_scenario_id,v_uid,'scenario_decision_submitted','A student submitted a scenario decision',jsonb_build_object('score',v_score,'action',p_action_key));
 return jsonb_build_object('score',v_score,'feedback',v_feedback,'submitted',true);
end; $$;

create or replace function public.complete_supply_scenario(p_scenario_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_classroom_id uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in is required'; end if;
 select classroom_id into v_classroom_id from public.scenarios where id=p_scenario_id and status='active';
 if v_classroom_id is null then raise exception 'Active scenario not found'; end if;
 if not public.is_class_teacher(v_classroom_id) then raise exception 'Only the classroom teacher can complete scenarios'; end if;
 update public.scenarios set status='completed',completed_at=now() where id=p_scenario_id;
 insert into public.activity_logs(classroom_id,scenario_id,actor_id,event_type,description) values(v_classroom_id,p_scenario_id,(select auth.uid()),'scenario_completed','Scenario completed by teacher');
 return true;
end; $$;
revoke all on function public.launch_supply_scenario(uuid,text) from public,anon;
revoke all on function public.submit_scenario_decision(uuid,text,text) from public,anon;
revoke all on function public.complete_supply_scenario(uuid) from public,anon;
grant execute on function public.launch_supply_scenario(uuid,text) to authenticated;
grant execute on function public.submit_scenario_decision(uuid,text,text) to authenticated;
grant execute on function public.complete_supply_scenario(uuid) to authenticated;
