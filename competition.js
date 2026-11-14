import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root=document.querySelector("#competitionWorkspace");
if(root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")){
 const db=createClient(SUPABASE_URL,SUPABASE_ANON_KEY);
 const $=id=>document.getElementById(id);
 const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
 const option=(label,value)=>{const n=el("option","",label);n.value=value;return n;};
 const roles=["procurement","manufacturer","warehouse","transport","operations","supplier","retailer","customer","finance","analyst"];
 let user=null,isTeacher=false,classrooms=[],templates=[],activeClassId=null,activeCompetition=null,activeTeam=null,activeRole=null;

 function say(message,success=false){$("competitionMessage").textContent=message;$("competitionMessage").classList.toggle("success",success);}
 function statusLabel(value){return (value||"").replaceAll("_"," ").toUpperCase();}
 function localDateTimeValue(value){const d=new Date(value);return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}
 function applySupplierNegotiationBounds(s){
  const baseLead=Number(s.base_lead_time_days),baseCost=Number(s.base_unit_cost),baseReliability=Number(s.base_reliability_score);
  const minLead=Math.max(1,Math.floor(baseLead*.7)),maxLead=Math.min(90,Math.ceil(baseLead*1.5));
  const minCost=(baseCost*.8).toFixed(2),maxCost=(baseCost*1.25).toFixed(2);
  const minReliability=Math.max(50,baseReliability-10),maxReliability=Math.min(99,baseReliability+5);
  $("competitionTermsLeadTime").min=String(minLead);$("competitionTermsLeadTime").max=String(maxLead);
  $("competitionTermsUnitCost").min=minCost;$("competitionTermsUnitCost").max=maxCost;
  $("competitionTermsReliability").min=String(minReliability);$("competitionTermsReliability").max=String(maxReliability);
  $("competitionSupplierNegotiationNote").textContent="Allowed range: "+minLead+"–"+maxLead+" days · "+minCost+"–"+maxCost+" cost · "+minReliability+"–"+maxReliability+" reliability. Improving all three terms at once is not allowed.";
 }
 function addEmpty(host,message){host.replaceChildren(el("p","empty-state",message));}
 function setHidden(id,value){$(id).hidden=value;}

 async function loadClassrooms(){
  if(isTeacher){
   const {data,error}=await db.from("classrooms").select("id,name").eq("teacher_id",user.id).order("created_at",{ascending:false});
   if(error)throw error;classrooms=data||[];
  }else{
   const {data,error}=await db.from("classroom_members").select("classrooms(id,name)").eq("student_id",user.id);
   if(error)throw error;classrooms=(data||[]).map(x=>x.classrooms).filter(Boolean);
  }
  $("competitionClassSelect").replaceChildren(...classrooms.map(c=>option(c.name,c.id)));
  if(!classrooms.length){activeClassId=null;setHidden("competitionCreateForm",true);setHidden("competitionManager",true);setHidden("competitionList",false);setHidden("competitionStudentPanel",true);addEmpty($("competitionList"),"Create or join a classroom first.");return;}
  setHidden("competitionList",true);setHidden("competitionCreateForm",isTeacher);
  activeClassId=classrooms[0].id;$("competitionClassSelect").value=activeClassId;
  await loadCompetitions();
 }

 async function loadTemplates(){
  const {data,error}=await db.from("company_templates").select("id,name,industry,business_model,case_study_note,source_urls").order("name");
  if(error)throw error;templates=data||[];
  $("competitionTemplateSelect").replaceChildren(...templates.map(t=>option(t.name+" · "+t.industry,t.id)));
 }

 async function loadCompetitions(){
  if(!activeClassId)return;
  const {data,error}=await db.from("competitions").select("id,title,status,created_at,starts_at,settings")
   .eq("classroom_id",activeClassId).order("created_at",{ascending:false});
  if(error)throw error;
  let rows=data||[];
  if(!isTeacher){
   const eligible=[];
   for(const comp of rows.filter(c=>["active","paused"].includes(c.status))){
    const {data:membership,error:memberError}=await db.from("competition_team_members").select("id,team_id,operational_role")
     .eq("competition_id",comp.id).eq("student_id",user.id).maybeSingle();
    if(memberError)throw memberError;
    if(membership)eligible.push({...comp,membership});
   }
   rows=eligible;
  }
  $("competitionSelect").replaceChildren(...rows.map(c=>option(c.title+" · "+statusLabel(c.status),c.id)));
  if(!rows.length){
   activeCompetition=null;setHidden("competitionWorkspaceEmpty",false);setHidden("competitionManager",true);setHidden("competitionList",false);
   setHidden("competitionStudentPanel",true);setHidden("competitionTeacherPanel",!isTeacher);
   addEmpty($("competitionList"),isTeacher?"No competition yet. Create one to begin.":"No active competition has been assigned to you yet.");
   setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
   return;
  }
  setHidden("competitionWorkspaceEmpty",true);setHidden("competitionList",true);
  activeCompetition=rows[0];$("competitionSelect").value=activeCompetition.id;
  await loadCompetition();
 }

 async function loadCompetition(){
  if(!activeCompetition)return;
  const {data:comp,error}=await db.from("competitions").select("id,title,status,settings,starts_at,completed_at")
   .eq("id",activeCompetition.id).single();
  if(error)throw error;activeCompetition={...activeCompetition,...comp};
  setHidden("competitionManager",false);
  $("competitionCurrentTitle").textContent=comp.title;
  $("competitionCurrentStatus").textContent=statusLabel(comp.status);
  setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
  if(isTeacher)await renderTeacherCompetition();else await renderStudentCompetition();
 }

 async function renderTeacherCompetition(){
  const [{data:teams,error:teamError},{data:students,error:studentError},{data:tasks,error:taskError},{data:decisions,error:decisionError}]=await Promise.all([
   db.from("competition_teams").select("id,name,company_template_id,company_templates(name,industry,business_model,case_study_note,source_urls)").eq("competition_id",activeCompetition.id).order("created_at"),
   db.from("classroom_members").select("student_id,profiles(full_name)").eq("classroom_id",activeClassId).order("joined_at"),
   db.from("competition_tasks").select("id,team_id,title,description,assigned_role,status,due_at,due_round,submitted_round,submission,review_note").eq("competition_id",activeCompetition.id).order("created_at",{ascending:false}),
   db.from("competition_decisions").select("id,team_id,student_id,domain,decision_type,selected_option,rationale,score,feedback,created_at,profiles(full_name)").eq("competition_id",activeCompetition.id).order("created_at",{ascending:false})
  ]);
  for(const e of [teamError,studentError,taskError,decisionError])if(e)throw e;
  const teamRows=teams||[],studentRows=students||[],taskRows=tasks||[],decisionRows=decisions||[];
  $("competitionTeams").replaceChildren();
  if(!teamRows.length){
   addEmpty($("competitionTeams"),"Create a balanced 4-team setup to assign students and company models.");
  }else{
   for(const team of teamRows){
    const card=el("article","competition-team-card");
    const head=el("div","competition-card-head");
    const copy=el("div");copy.append(el("h4","",team.name),el("p","",team.company_templates?.industry+" · "+team.company_templates?.business_model));
    if(team.company_templates?.case_study_note)copy.append(el("small","competition-case-note",team.company_templates.case_study_note));
    const teamSources=el("div","competition-source-links");
    (team.company_templates?.source_urls||[]).forEach((url,i)=>{const link=el("a","","Official source "+(i+1));link.href=url;link.target="_blank";link.rel="noopener noreferrer";teamSources.append(link);});
    if(teamSources.childElementCount)copy.append(teamSources);
    head.append(copy,el("span","competition-status",teamRows.length+" teams"));card.append(head);
    const {data:members,error:membersError}=await db.from("competition_team_members").select("id,student_id,operational_role,profiles(full_name)")
     .eq("competition_id",activeCompetition.id).eq("team_id",team.id).order("joined_at");
    if(membersError)throw membersError;
    const list=el("div","competition-member-list");
    for(const member of members||[]){
     const line=el("div","competition-member-line");
     line.append(el("span","",member.profiles?.full_name||"Student"),el("small","",statusLabel(member.operational_role)));
     list.append(line);
    }
    card.append(list);
    if(activeCompetition.status==="draft"){
     const form=el("form","competition-inline-form");
     const studentSelect=el("select","");studentSelect.required=true;studentSelect.append(option("Select student…",""));
     const assigned=new Set((members||[]).map(m=>m.student_id));
     for(const s of studentRows)if(!assigned.has(s.student_id))studentSelect.append(option(s.profiles?.full_name||"Student",s.student_id));
     const roleSelect=el("select","");for(const r of roles)roleSelect.append(option(statusLabel(r),r));
     const add=el("button","secondary-button","Assign");add.type="submit";
     form.append(studentSelect,roleSelect,add);
     form.addEventListener("submit",async e=>{
      e.preventDefault();add.disabled=true;
      try{
       const {error}=await db.rpc("assign_competition_member",{p_competition_id:activeCompetition.id,p_team_id:team.id,p_student_id:studentSelect.value,p_operational_role:roleSelect.value});
       if(error)throw error;say("Student assigned to "+team.name,true);await loadCompetition();
      }catch(err){say(err.message);add.disabled=false;}
     });
     card.append(form);
    }
    $("competitionTeams").append(card);
   }
  }
  $("competitionTaskTeam").replaceChildren(...teamRows.map(t=>option(t.name,t.id)));
  $("competitionTaskRole").replaceChildren(...roles.map(r=>option(statusLabel(r),r)));
  $("competitionTaskList").replaceChildren();
  if(!taskRows.length)addEmpty($("competitionTaskList"),"No team tasks yet.");
  for(const task of taskRows){
   const card=el("article","competition-task-card");
   card.append(el("div","competition-card-head",task.title),el("p","",task.description||"No additional instructions"),el("small","",statusLabel(task.assigned_role)+" · "+statusLabel(task.status)+(task.due_round?" · Due round "+task.due_round:"")+(task.submitted_round?" · Submitted round "+task.submitted_round:"")+(task.due_round&&task.submitted_round>task.due_round?" · LATE":"")));
   if(task.submission)card.append(el("pre","competition-submission",JSON.stringify(task.submission,null,2)));
   if(task.status==="submitted"){
    const review=el("div","competition-review");
    const note=el("input","");note.placeholder="Feedback (optional)";
    const approve=el("button","secondary-button","Approve");approve.type="button";
    const reject=el("button","secondary-button","Request changes");reject.type="button";
    for(const [btn,ok] of [[approve,true],[reject,false]])btn.addEventListener("click",async()=>{
     btn.disabled=true;try{const {error}=await db.rpc("review_competition_task",{p_task_id:task.id,p_approved:ok,p_review_note:note.value.trim()});if(error)throw error;say(ok?"Task approved.":"Changes requested.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
    });
    review.append(note,approve,reject);card.append(review);
   }
   $("competitionTaskList").append(card);
  }
  $("competitionDecisionList").replaceChildren();
  if(!decisionRows.length)addEmpty($("competitionDecisionList"),"No decisions submitted yet.");
  for(const d of decisionRows){
   const card=el("article","competition-decision-card");
   card.append(el("b","",d.profiles?.full_name||"Student"),el("p","",statusLabel(d.domain)+" · "+d.selected_option),el("p","",d.rationale));
   if(d.score!==null)card.append(el("strong","",d.score+"/100 · "+(d.feedback||"Evaluated")));
   else{
    const form=el("form","competition-inline-form");
    const score=el("input","");score.type="number";score.min="0";score.max="100";score.step="1";score.placeholder="Score /100";score.required=true;
    const feedback=el("input","");feedback.placeholder="Feedback";
    const submit=el("button","secondary-button","Evaluate");submit.type="submit";
    form.append(score,feedback,submit);
    form.addEventListener("submit",async e=>{e.preventDefault();submit.disabled=true;try{const {error}=await db.rpc("evaluate_competition_decision",{p_decision_id:d.id,p_score:Number(score.value),p_feedback:feedback.value.trim()});if(error)throw error;say("Decision evaluated.",true);await loadCompetition();}catch(err){say(err.message);submit.disabled=false;}});
    card.append(form);
   }
   $("competitionDecisionList").append(card);
  }
  const {data:metricRows,error:metricError}=await db.from("competition_team_live_metrics").select("*").eq("competition_id",activeCompetition.id).order("total_score",{ascending:false});
  if(metricError)throw metricError;
  const {data:taskMetricRows,error:taskMetricError}=await db.from("competition_task_performance").select("team_id,due_tasks,approved_tasks,completion_pct,awaiting_review,late_submissions").eq("competition_id",activeCompetition.id);
  if(taskMetricError)throw taskMetricError;
  const taskMetricByTeam=new Map((taskMetricRows||[]).map(x=>[x.team_id,x]));
  $("competitionLeaderboard").replaceChildren();
  if(!metricRows?.length)addEmpty($("competitionLeaderboard"),"No team performance records yet.");
  for(const [index,m] of (metricRows||[]).entries()){
   const row=el("article","competition-score-row");
   const left=el("div");const tm=taskMetricByTeam.get(m.team_id);
    left.append(el("b","",(index+1)+". "+m.team_name),el("small","",m.company_name+" · data coverage "+Number(m.score_coverage_pct||0).toFixed(0)+"% · Tasks "+(tm?tm.approved_tasks+"/"+tm.due_tasks+" approved":"not assigned")));
    const pct=value=>value===null||value===undefined?"—":Number(value).toFixed(1)+"%";
    left.append(el("small","competition-kpi-breakdown","OTIF "+pct(m.service_score)+" · Cost "+pct(m.cost_score)+" · Inventory "+pct(m.inventory_score)+" · Lead time "+pct(m.lead_time_score)+" · Production plan "+pct(m.productivity_score)+" · Decisions "+pct(m.decision_quality_score)));
   row.append(left,el("strong","",m.total_score===null?"Awaiting data":Number(m.total_score).toFixed(1)+"/100"));
   $("competitionLeaderboard").append(row);
  }
  const individuals=new Map();
  for(const d of decisionRows){
   if(!individuals.has(d.student_id))individuals.set(d.student_id,{name:d.profiles?.full_name||"Student",scores:[],count:0});
   const item=individuals.get(d.student_id);item.count++;if(d.score!==null)item.scores.push(Number(d.score));
  }
  $("competitionIndividualRanking").replaceChildren();
  const ranked=[...individuals.values()].filter(x=>x.scores.length).map(x=>({...x,average:x.scores.reduce((a,b)=>a+b,0)/x.scores.length})).sort((a,b)=>b.average-a.average);
  if(!ranked.length)addEmpty($("competitionIndividualRanking"),"Individual ranking appears after decisions have been evaluated.");
  for(const [index,p] of ranked.entries()){
   const row=el("article","competition-score-row");row.append(el("b","",(index+1)+". "+p.name+" · "+p.count+" decisions"),el("strong","",p.average.toFixed(1)+"/100"));
   $("competitionIndividualRanking").append(row);
  }
  const {data:clock,error:clockError}=await db.from("competition_simulation_clock").select("current_round,round_limit,virtual_now").eq("competition_id",activeCompetition.id).maybeSingle();
  if(clockError)throw clockError;
  $("competitionRoundInfo").textContent=clock?"Round "+clock.current_round+" / "+clock.round_limit+" · Simulation date "+new Date(clock.virtual_now).toLocaleDateString():"Rounds begin when the competition starts.";
  setHidden("competitionAdvanceRound",activeCompetition.status!=="active");
  $("competitionAdvanceRound").disabled=!clock||clock.current_round>=clock.round_limit;
  setHidden("competitionCompleteButton",activeCompetition.status!=="active"||!clock||clock.current_round<clock.round_limit);
  const draft=activeCompetition.status==="draft";
  setHidden("competitionAutoSetup",!draft||teamRows.length>0);
  setHidden("competitionManualTeamForm",!draft);
  setHidden("competitionTaskForm",!["draft","active"].includes(activeCompetition.status)||!teamRows.length);
  setHidden("competitionTaskPackButton",!["draft","active"].includes(activeCompetition.status)||!teamRows.length||taskRows.length>0);
  setHidden("competitionStartButton",!draft||teamRows.length<2);
  $("competitionStartButton").textContent="Start competition";
  setHidden("competitionPauseButton",!["active","paused"].includes(activeCompetition.status));
  $("competitionPauseButton").textContent=activeCompetition.status==="paused"?"Resume competition":"Pause competition";
  $("competitionAutoSetupButton").disabled=!draft||teamRows.length>0;
  if(!draft){$("competitionSetupNote").textContent="Team assignments are locked after the competition starts."; }
  else $("competitionSetupNote").textContent="Create 2–4 balanced company teams. Every team needs five core roles: Procurement, Supplier, Manufacturer, Warehouse and Transport (minimum five students per team).";
 }

 async function renderStudentCompetition(){
  const {data:membership,error}=await db.from("competition_team_members").select("team_id,operational_role")
   .eq("competition_id",activeCompetition.id).eq("student_id",user.id).single();
  if(error)throw error;activeTeam=membership.team_id;activeRole=membership.operational_role;
  const {data:team,error:teamError}=await db.from("competition_teams").select("id,name,company_templates(name,industry,business_model,case_study_note,source_urls)")
   .eq("id",activeTeam).single();
  if(teamError)throw teamError;
  $("competitionStudentTeam").textContent=team.name+" · "+team.company_templates?.name;
   $("competitionStudentCompanyNote").textContent=team.company_templates?.case_study_note||"Educational case study; simulation figures are synthetic.";
   const studentSources=$("competitionStudentCompanySources");studentSources.replaceChildren();
   (team.company_templates?.source_urls||[]).forEach((url,i)=>{const link=el("a","", "Official source "+(i+1));link.href=url;link.target="_blank";link.rel="noopener noreferrer";studentSources.append(link);});
  $("competitionStudentRole").textContent=statusLabel(activeRole);
  const {data:tasks,error:taskError}=await db.from("competition_tasks").select("id,title,description,assigned_role,assigned_to,status,due_at,due_round,submitted_round,submission,review_note")
   .eq("competition_id",activeCompetition.id).eq("team_id",activeTeam).order("created_at",{ascending:false});
  if(taskError)throw taskError;
  const myTasks=(tasks||[]).filter(t=>(!t.assigned_to||t.assigned_to===user.id)&&(!t.assigned_role||t.assigned_role===activeRole));
  $("competitionStudentTasks").replaceChildren();
  if(!myTasks.length)addEmpty($("competitionStudentTasks"),"No tasks have been assigned to your role yet.");
  for(const task of myTasks){
   const card=el("article","competition-task-card");
   card.append(el("b","",task.title),el("p","",task.description),el("small","",statusLabel(task.status)+(task.due_round?" · Due round "+task.due_round:"")+(task.due_at?" · Due "+new Date(task.due_at).toLocaleString():"")+(task.due_round&&task.submitted_round>task.due_round?" · LATE":"")));
   if(task.review_note)card.append(el("p","competition-review-note",task.review_note));
   if(["pending","in_progress","rejected"].includes(task.status)&&activeCompetition.status==="active"){
    const form=el("form","competition-submit-form");
    const answer=el("textarea","");answer.rows=3;answer.maxLength=10000;answer.placeholder="Describe your work, calculations and evidence…";answer.required=true;
    const btn=el("button","primary-button","Submit task");btn.type="submit";
    form.append(answer,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("submit_competition_task",{p_task_id:task.id,p_submission:{response:answer.value.trim(),role:activeRole,submitted_at:new Date().toISOString()}});if(error)throw error;say("Task submitted for review.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}});
    card.append(form);
   }else if(task.submission)card.append(el("pre","competition-submission",JSON.stringify(task.submission,null,2)));
   $("competitionStudentTasks").append(card);
  }
  const {data:decisions,error:decisionError}=await db.from("competition_decisions").select("domain,selected_option,rationale,score,feedback,created_at")
   .eq("competition_id",activeCompetition.id).eq("student_id",user.id).order("created_at",{ascending:false});
  if(decisionError)throw decisionError;
  $("competitionStudentDecisionHistory").replaceChildren();
  if(!decisions?.length)addEmpty($("competitionStudentDecisionHistory"),"Your decision history will appear here.");
  for(const d of decisions||[]){
   const row=el("article","competition-decision-card");
   row.append(el("b","",statusLabel(d.domain)+" · "+d.selected_option),el("p","",d.rationale),el("small","",d.score===null?"Awaiting evaluation":"Score "+d.score+"/100 · "+(d.feedback||"")));
   $("competitionStudentDecisionHistory").append(row);
  }
  await loadTeamOperations();
  await loadPublicCompetitionResults();
  setHidden("competitionDecisionForm",activeCompetition.status!=="active");
 }


 async function loadTeamOperations(){
  const teamId=activeTeam;
  const [metricResult,supplierResult,inventoryResult,poResult,orderResult,shipmentResult,clockResult,taskMetricResult,teamResult,productionResult]=await Promise.all([
   db.from("competition_team_live_metrics").select("*").eq("team_id",teamId).single(),
   db.from("competition_suppliers").select("id,supplier_code,name,lead_time_days,unit_cost,reliability_score,base_lead_time_days,base_unit_cost,base_reliability_score,active").eq("team_id",teamId).order("unit_cost"),
   db.from("competition_inventory").select("sku,item_name,item_type,quantity,reorder_level,unit_cost").eq("team_id",teamId).order("item_type"),
   db.from("competition_purchase_orders").select("id,po_number,sku,item_name,quantity,received_quantity,unit_cost,status,expected_at,available_at").eq("team_id",teamId).order("created_at",{ascending:false}),
   db.from("competition_customer_orders").select("id,order_number,sku,item_name,quantity,unit_price,status,due_at,delivered_at").eq("team_id",teamId).order("created_at",{ascending:false}),
   db.from("competition_shipments").select("id,order_id,quantity,destination,carrier,status,transport_cost,eta,delivered_at").eq("team_id",teamId).order("dispatched_at",{ascending:false}),
   db.from("competition_simulation_clock").select("current_round,round_limit,virtual_now").eq("competition_id",activeCompetition.id).single(),
   db.from("competition_task_performance").select("due_tasks,approved_tasks,completion_pct,awaiting_review,late_submissions").eq("team_id",teamId).maybeSingle(),
   db.from("competition_teams").select("production_capacity_units").eq("id",teamId).single(),
   db.from("competition_production_runs").select("production_round,produced_quantity").eq("team_id",teamId).eq("status","completed")
  ]);
  for(const r of [metricResult,supplierResult,inventoryResult,poResult,orderResult,shipmentResult,clockResult,taskMetricResult,teamResult,productionResult])if(r.error)throw r.error;
  const canOperate=activeCompetition.status==="active";
  for(const id of ["competitionSupplierTermsForm","competitionPurchaseOrderForm","competitionProductionForm","competitionCustomerOrderForm","competitionDecisionForm"]){const form=$(id);if(form)form.querySelectorAll("input,select,textarea,button").forEach(control=>control.disabled=!canOperate);}
  const producedThisRound=(productionResult.data||[]).filter(x=>x.production_round===clockResult.data.current_round).reduce((sum,x)=>sum+Number(x.produced_quantity),0);
  const remainingProductionCapacity=Math.max(0,Number(teamResult.data.production_capacity_units)-producedThisRound);
  $("competitionCustomerDue").min=localDateTimeValue(clockResult.data.virtual_now);
  $("competitionProductionQuantity").max=String(Math.max(1,remainingProductionCapacity));
  $("competitionProductionQuantity").disabled=remainingProductionCapacity===0||!canOperate;
  $("competitionProductionCapacityNote").textContent="Round "+clockResult.data.current_round+": "+producedThisRound+" / "+teamResult.data.production_capacity_units+" units produced · "+remainingProductionCapacity+" remaining.";
  const productionSubmit=$("competitionProductionForm").querySelector("button");
  if(productionSubmit)productionSubmit.disabled=remainingProductionCapacity===0||!canOperate;
  const m=metricResult.data,suppliers=supplierResult.data||[],inventory=inventoryResult.data||[],pos=poResult.data||[],orders=orderResult.data||[],shipments=shipmentResult.data||[];
  const metricCards=[
   ["Cash balance",Number(m.cash_balance).toLocaleString(undefined,{maximumFractionDigits:0})],
   ["OTIF",m.service_score===null?"—":Number(m.service_score).toFixed(1)+"%"],
   ["Inventory units",Number(m.inventory_units).toLocaleString()],
   ["Low-stock SKUs",String(m.low_stock_skus)],
   ["Production",Number(m.produced_units).toLocaleString()+" units"],
   ["Avg. lead time",m.avg_delivery_days===null?"—":Number(m.avg_delivery_days).toFixed(1)+" days"],
   ["Live score",m.total_score===null?"Awaiting data":Number(m.total_score).toFixed(1)+"/100"],
   ["Cost efficiency",m.cost_score===null?"—":Number(m.cost_score).toFixed(1)+"%"],
   ["Inventory balance",m.inventory_score===null?"—":Number(m.inventory_score).toFixed(1)+"%"],
   ["Lead-time score",m.lead_time_score===null?"—":Number(m.lead_time_score).toFixed(1)+"%"],
   ["Production plan",m.productivity_score===null?"—":Number(m.productivity_score).toFixed(1)+"%"],
   ["Decision quality",m.decision_quality_score===null?"—":Number(m.decision_quality_score).toFixed(1)+"%"],
   ["Score coverage",Number(m.score_coverage_pct||0).toFixed(0)+"%"],
   ["Task completion",taskMetricResult.data?.completion_pct===null||!taskMetricResult.data?"—":Number(taskMetricResult.data.completion_pct).toFixed(0)+"%"],
   ["Simulation round",clockResult.data.current_round+" / "+clockResult.data.round_limit],
   ["Simulation date",new Date(clockResult.data.virtual_now).toLocaleDateString()]
  ];
  $("competitionLiveMetrics").replaceChildren();
  for(const [label,value] of metricCards){const card=el("div","competition-metric");card.append(el("span","",label),el("strong","",value));$("competitionLiveMetrics").append(card);}
  $("competitionSupplierList").replaceChildren();
  if(!suppliers.length)addEmpty($("competitionSupplierList"),"No suppliers registered.");
  for(const s of suppliers){const row=el("article","competition-task-card");row.append(el("b","",s.name+" · "+s.supplier_code),el("p","",s.lead_time_days+" days · "+Number(s.unit_cost).toFixed(2)+" per unit · "+s.reliability_score+"% reliability"));$("competitionSupplierList").append(row);}
  for(const id of ["competitionPOSupplier","competitionTermsSupplier"]){
   $(id).replaceChildren(...suppliers.filter(s=>s.active).map(s=>option(s.name+" · "+s.lead_time_days+"d · "+Number(s.unit_cost).toFixed(2),s.id)));
  }
  const selectedSupplier=suppliers.find(s=>s.id===$("competitionTermsSupplier").value)||suppliers[0];
  if(selectedSupplier){$("competitionTermsSupplier").value=selectedSupplier.id;$("competitionTermsLeadTime").value=selectedSupplier.lead_time_days;$("competitionTermsUnitCost").value=selectedSupplier.unit_cost;$("competitionTermsReliability").value=selectedSupplier.reliability_score;applySupplierNegotiationBounds(selectedSupplier);}
  $("competitionPurchaseOrderList").replaceChildren();
  const outstandingPOs=pos.filter(p=>["placed","partially_received"].includes(p.status));
  if(!outstandingPOs.length)addEmpty($("competitionPurchaseOrderList"),"No outstanding purchase orders.");
  for(const po of outstandingPOs){
   const card=el("article","competition-task-card");card.append(el("b","",po.po_number+" · "+po.item_name),el("p","",po.received_quantity+" / "+po.quantity+" received · Expected "+new Date(po.expected_at).toLocaleDateString()+" · "+Number(po.unit_cost).toFixed(2)+" / unit · Available "+new Date(po.available_at||po.expected_at).toLocaleDateString()));
   const supplierAvailable=new Date(clockResult.data.virtual_now)>=new Date(po.available_at||po.expected_at);
   if(activeCompetition.status==="active"&&activeRole==="warehouse"&&supplierAvailable){const form=el("form","competition-inline-form"),qty=el("input","");qty.type="number";qty.min="1";qty.max=String(po.quantity-po.received_quantity);qty.value=qty.max;qty.required=true;
   const btn=el("button","secondary-button","Receive stock");btn.type="submit";form.append(qty,btn);
   form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {data,error}=await db.rpc("competition_receive_purchase_order",{p_purchase_order_id:po.id,p_quantity:Number(qty.value)});if(error)throw error;say("Received "+data.received_quantity+" units; stock and cash updated.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
   card.append(form);}else if(activeCompetition.status==="active"&&activeRole==="warehouse"){card.append(el("small","", "Awaiting supplier availability · "+new Date(po.available_at||po.expected_at).toLocaleDateString()));}
   $("competitionPurchaseOrderList").append(card);
  }
  $("competitionInventoryList").replaceChildren();
  if(!inventory.length)addEmpty($("competitionInventoryList"),"No inventory records.");
  for(const item of inventory){const row=el("article","competition-task-card");row.append(el("b","",item.item_name+" · "+item.sku),el("p","",statusLabel(item.item_type)+" · "+item.quantity+" units · reorder at "+item.reorder_level+" · "+Number(item.unit_cost).toFixed(2)+" / unit"));$("competitionInventoryList").append(row);}
  $("competitionCustomerOrderList").replaceChildren();
  const openOrders=orders.filter(o=>!["delivered","cancelled"].includes(o.status));
  if(!openOrders.length)addEmpty($("competitionCustomerOrderList"),"No open customer orders.");
  for(const order of openOrders){
   const card=el("article","competition-task-card");card.append(el("b","",order.order_number+" · "+order.item_name),el("p","",order.quantity+" units · "+statusLabel(order.status)+" · Due "+new Date(order.due_at).toLocaleDateString()));
   const shipped=shipments.filter(s=>s.order_id===order.id&&s.status!=="cancelled").reduce((sum,s)=>sum+Number(s.quantity),0);
   card.append(el("small","",Math.max(0,order.quantity-shipped)+" units remaining to ship"));
   if(activeRole==="transport"&&activeCompetition.status==="active"&&order.quantity>shipped){
    const form=el("form","competition-inline-form");
    const qty=el("input","");qty.type="number";qty.min="1";qty.max=String(order.quantity-shipped);qty.value=qty.max;qty.required=true;qty.setAttribute("aria-label","Quantity to dispatch");
    const origin=el("input","");origin.placeholder="Origin";origin.value="Company warehouse";origin.required=true;
    const dest=el("input","");dest.placeholder="Destination";dest.value="Customer distribution centre";dest.required=true;
    const carrier=el("input","");carrier.placeholder="Carrier";carrier.value="Regional carrier";carrier.required=true;
    const cost=el("input","");cost.type="number";cost.min="0";cost.step=".01";cost.value="100";cost.required=true;cost.setAttribute("aria-label","Transport cost");
    const btn=el("button","secondary-button","Dispatch");btn.type="submit";form.append(qty,origin,dest,carrier,cost,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("competition_dispatch_shipment",{p_order_id:order.id,p_quantity:Number(qty.value),p_origin:origin.value.trim(),p_destination:dest.value.trim(),p_carrier:carrier.value.trim(),p_transport_cost:Number(cost.value)});if(error)throw error;say("Shipment dispatched. Inventory and cash were updated.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
    card.append(form);
   }
   $("competitionCustomerOrderList").append(card);
  }
  $("competitionShipmentList").replaceChildren();
  if(!shipments.length)addEmpty($("competitionShipmentList"),"No shipments have been dispatched.");
  for(const shipment of shipments){
   const card=el("article","competition-task-card");card.append(el("b","",shipment.destination+" · "+shipment.quantity+" units"),el("p","",shipment.carrier+" · "+statusLabel(shipment.status)+" · ETA "+new Date(shipment.eta).toLocaleString()));
   if(activeRole==="transport"&&["in_transit","delayed"].includes(shipment.status)&&activeCompetition.status==="active"){
    if(new Date(clockResult.data.virtual_now)>=new Date(shipment.eta)){
     const btn=el("button","secondary-button","Confirm delivery");btn.type="button";btn.addEventListener("click",async()=>{btn.disabled=true;try{const {data,error}=await db.rpc("competition_deliver_shipment",{p_shipment_id:shipment.id});if(error)throw error;say(data.on_time?"Delivered on time. Revenue recorded.":"Delivered late. Revenue recorded.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});card.append(btn);
    }else{card.append(el("small","", "Shipment in transit · Delivery can be confirmed after "+new Date(shipment.eta).toLocaleDateString()));}
   }
   $("competitionShipmentList").append(card);
  }
  setHidden("competitionSupplierPanel",!["supplier","procurement"].includes(activeRole));
  setHidden("competitionSupplierTermsForm",activeRole!=="supplier"||activeCompetition.status!=="active");
  setHidden("competitionProcurementPanel",activeRole!=="procurement");
  setHidden("competitionWarehousePanel",activeRole!=="warehouse");
  setHidden("competitionManufacturerPanel",activeRole!=="manufacturer");
  setHidden("competitionCustomerPanel",!["customer","retailer","operations"].includes(activeRole));
  setHidden("competitionTransportPanel",activeRole!=="transport");
 }


 async function loadPublicCompetitionResults(){
  const [teamsResult,peopleResult]=await Promise.all([
   db.rpc("get_competition_leaderboard",{p_competition_id:activeCompetition.id}),
   db.rpc("get_competition_individual_leaderboard",{p_competition_id:activeCompetition.id})
  ]);
  if(teamsResult.error)throw teamsResult.error;if(peopleResult.error)throw peopleResult.error;
  const teams=(teamsResult.data||[]).sort((a,b)=>(b.total_score??-1)-(a.total_score??-1));
  $("competitionPublicLeaderboard").replaceChildren();
  if(!teams.length)addEmpty($("competitionPublicLeaderboard"),"No team results are available yet.");
  for(const [i,t] of teams.entries()){
   const row=el("article","competition-score-row");
   const left=el("div");left.append(el("b","",(i+1)+". "+t.team_name),el("small","",t.company_name+" · coverage "+Number(t.score_coverage_pct||0).toFixed(0)+"% · OTIF "+(t.service_score===null?"—":Number(t.service_score).toFixed(1)+"%")));
   row.append(left,el("strong","",t.total_score===null?"In progress":Number(t.total_score).toFixed(1)+"/100"));
   $("competitionPublicLeaderboard").append(row);
  }
  const people=(peopleResult.data||[]).sort((a,b)=>Number(b.average_score)-Number(a.average_score));
  $("competitionPublicIndividualRanking").replaceChildren();
  if(!people.length)addEmpty($("competitionPublicIndividualRanking"),"Individual rankings appear after teacher evaluation.");
  for(const [i,p] of people.entries()){
   const row=el("article","competition-score-row");
   row.append(el("b","",(i+1)+". "+(p.full_name||"Student")+" · "+p.team_name+" · "+p.evaluated_decisions+" evaluated decisions"),
    el("strong","",Number(p.average_score).toFixed(1)+"/100"));
   $("competitionPublicIndividualRanking").append(row);
  }
 }

 async function initialize(session){
  if(!session?.user){root.hidden=true;return;}
  user=session.user;
  try{
   const {data:profile,error}=await db.from("profiles").select("platform_role").eq("id",user.id).single();if(error)throw error;
   isTeacher=profile.platform_role==="teacher";root.hidden=false;
   $("competitionAccessNote").textContent=isTeacher?"Teacher control · configure teams, assign work and review decisions.":"Your company workspace · complete assigned work and record operational decisions.";
   setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
   if(isTeacher)await loadTemplates();
   await loadClassrooms();
  }catch(err){root.hidden=false;say("Competition engine could not load: "+err.message);}
 }

 $("competitionClassSelect").addEventListener("change",async()=>{activeClassId=$("competitionClassSelect").value;try{await loadCompetitions();say("");}catch(err){say(err.message);}});
 $("competitionSelect").addEventListener("change",async()=>{activeCompetition={id:$("competitionSelect").value};try{await loadCompetition();say("");}catch(err){say(err.message);}});
 $("competitionCreateForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionCreateButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("create_competition",{p_classroom_id:activeClassId,p_title:$("competitionTitle").value.trim(),p_settings:{round_count:4,round_duration_minutes:20,scoring_version:"v1"}});if(error)throw error;
   $("competitionTitle").value="";say("Competition created. Configure teams next.",true);await loadCompetitions();$("competitionSelect").value=data;activeCompetition={id:data};await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionAutoSetupButton").addEventListener("click",async()=>{
  const btn=$("competitionAutoSetupButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("create_balanced_competition_teams",{p_competition_id:activeCompetition.id,p_team_count:Number($("competitionTeamCount").value)});if(error)throw error;
   say(data.team_count+" balanced teams created and "+data.student_count+" students assigned.",true);await loadCompetition();
  }catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionManualTeamForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionManualTeamButton");btn.disabled=true;
  try{const {error}=await db.rpc("create_competition_team",{p_competition_id:activeCompetition.id,p_team_name:$("competitionManualTeamName").value.trim(),p_company_template_id:$("competitionTemplateSelect").value});if(error)throw error;
   $("competitionManualTeamName").value="";say("Team created. Assign its students below.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionTaskPackButton").addEventListener("click",async()=>{
  const btn=$("competitionTaskPackButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("create_competition_standard_task_pack",{p_competition_id:activeCompetition.id});if(error)throw error;say(data+" role-specific tasks created across all teams.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionTaskForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionTaskButton");btn.disabled=true;
  try{const {error}=await db.rpc("create_competition_task",{p_competition_id:activeCompetition.id,p_team_id:$("competitionTaskTeam").value,p_title:$("competitionTaskTitle").value.trim(),p_description:$("competitionTaskDescription").value.trim(),p_assigned_to:null,p_assigned_role:$("competitionTaskRole").value,p_priority:$("competitionTaskPriority").value,p_due_at:$("competitionTaskDue").value?new Date($("competitionTaskDue").value).toISOString():null});if(error)throw error;
   $("competitionTaskForm").reset();say("Task assigned to the selected team role.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionPauseButton").addEventListener("click",async()=>{
  const btn=$("competitionPauseButton");btn.disabled=true;
  const next=activeCompetition.status==="paused"?"active":"paused";
  try{const {error}=await db.rpc("set_competition_status",{p_competition_id:activeCompetition.id,p_status:next});if(error)throw error;say(next==="paused"?"Competition paused. Operational actions are locked.":"Competition resumed.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionStartButton").addEventListener("click",async()=>{
  const btn=$("competitionStartButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("set_competition_status",{p_competition_id:activeCompetition.id,p_status:"active"});if(error)throw error;say("Competition started. Students can now work.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });

 $("competitionTermsSupplier").addEventListener("change",async()=>{
  const {data,error}=await db.from("competition_suppliers").select("lead_time_days,unit_cost,reliability_score,base_lead_time_days,base_unit_cost,base_reliability_score").eq("id",$("competitionTermsSupplier").value).single();
  if(!error&&data){$("competitionTermsLeadTime").value=data.lead_time_days;$("competitionTermsUnitCost").value=data.unit_cost;$("competitionTermsReliability").value=data.reliability_score;applySupplierNegotiationBounds(data);}
 });
 $("competitionSupplierTermsForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionSupplierTermsForm").querySelector("button");btn.disabled=true;
  try{const {error}=await db.rpc("competition_update_supplier_terms",{p_supplier_id:$("competitionTermsSupplier").value,p_lead_time_days:Number($("competitionTermsLeadTime").value),p_unit_cost:Number($("competitionTermsUnitCost").value),p_reliability_score:Number($("competitionTermsReliability").value)});if(error)throw error;say("Supplier terms updated. New purchase orders will use these terms.",true);await loadTeamOperations();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionPurchaseOrderForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionPurchaseOrderForm").querySelector("button");btn.disabled=true;
  try{const {error}=await db.rpc("competition_create_purchase_order",{p_team_id:activeTeam,p_supplier_id:$("competitionPOSupplier").value,p_sku:$("competitionPOSku").value.trim(),p_item_name:$("competitionPOItemName").value.trim(),p_quantity:Number($("competitionPOQuantity").value)});if(error)throw error;say("Purchase order placed. Lead time and supplier reliability determine availability.",true);await loadTeamOperations();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionProductionForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionProductionForm").querySelector("button");btn.disabled=true;
  try{const {data,error}=await db.rpc("competition_complete_production",{p_team_id:activeTeam,p_quantity:Number($("competitionProductionQuantity").value)});if(error)throw error;say("Production completed: "+data.produced_quantity+" units. Raw material and cash updated.",true);await loadTeamOperations();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionCustomerOrderForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionCustomerOrderForm").querySelector("button");btn.disabled=true;
  try{const due=$("competitionCustomerDue").value;if(!due)throw new Error("Choose a due date");const {error}=await db.rpc("competition_create_customer_order",{p_team_id:activeTeam,p_order_number:$("competitionCustomerOrderNumber").value.trim(),p_sku:$("competitionCustomerSku").value.trim(),p_item_name:$("competitionCustomerItem").value.trim(),p_quantity:Number($("competitionCustomerQty").value),p_unit_price:Number($("competitionCustomerPrice").value),p_due_at:new Date(due).toISOString()});if(error)throw error;say("Customer order created.",true);$("competitionCustomerOrderForm").reset();await loadTeamOperations();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionCompleteButton").addEventListener("click",async()=>{
  const btn=$("competitionCompleteButton");btn.disabled=true;
  try{const {error}=await db.rpc("set_competition_status",{p_competition_id:activeCompetition.id,p_status:"completed"});if(error)throw error;say("Competition completed. Final results are locked.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionAdvanceRound").addEventListener("click",async()=>{
  const btn=$("competitionAdvanceRound");btn.disabled=true;
  try{const {data,error}=await db.rpc("competition_advance_round",{p_competition_id:activeCompetition.id});if(error)throw error;say("Advanced to round "+data.current_round+". Simulation time moved forward seven days.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionCalculateScores").addEventListener("click",async()=>{
  const btn=$("competitionCalculateScores");btn.disabled=true;
  try{const {data:clock,error:clockError}=await db.from("competition_simulation_clock").select("current_round").eq("competition_id",activeCompetition.id).single();if(clockError)throw clockError;const {data,error}=await db.rpc("calculate_competition_scores",{p_competition_id:activeCompetition.id,p_round_number:clock.current_round});if(error)throw error;say(data+" team score snapshots calculated for round "+clock.current_round+".",true);await loadCompetition();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionDecisionForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionDecisionButton");btn.disabled=true;
  try{const {error}=await db.rpc("record_competition_decision",{p_competition_id:activeCompetition.id,p_team_id:activeTeam,p_domain:$("competitionDecisionDomain").value,p_decision_type:$("competitionDecisionType").value.trim(),p_selected_option:$("competitionDecisionOption").value.trim(),p_rationale:$("competitionDecisionRationale").value.trim(),p_inputs:{role:activeRole}});if(error)throw error;
   $("competitionDecisionForm").reset();say("Your decision was recorded.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 window.addEventListener("classroom-updated",async()=>{try{await loadClassrooms();say("Classroom list refreshed.",true);}catch(err){say(err.message);}});
 db.auth.getSession().then(({data})=>initialize(data.session));
 db.auth.onAuthStateChange((_event,session)=>{if(session)setTimeout(()=>initialize(session),0);else{root.hidden=true;user=null;activeCompetition=null;}});
}
