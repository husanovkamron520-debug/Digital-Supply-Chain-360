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
  if(!classrooms.length){activeClassId=null;addEmpty($("competitionList"),"Create or join a classroom first.");return;}
  activeClassId=classrooms[0].id;$("competitionClassSelect").value=activeClassId;
  await loadCompetitions();
 }

 async function loadTemplates(){
  const {data,error}=await db.from("company_templates").select("id,name,industry,business_model").order("name");
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
   activeCompetition=null;setHidden("competitionWorkspaceEmpty",false);setHidden("competitionManager",true);
   addEmpty($("competitionList"),isTeacher?"No competition yet. Create one to begin.":"No active competition has been assigned to you yet.");
   setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
   return;
  }
  setHidden("competitionWorkspaceEmpty",true);
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
   db.from("competition_teams").select("id,name,company_template_id,company_templates(name,industry,business_model)").eq("competition_id",activeCompetition.id).order("created_at"),
   db.from("classroom_members").select("student_id,profiles(full_name)").eq("classroom_id",activeClassId).order("joined_at"),
   db.from("competition_tasks").select("id,team_id,title,description,assigned_role,status,due_at,submission,review_note").eq("competition_id",activeCompetition.id).order("created_at",{ascending:false}),
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
   card.append(el("div","competition-card-head",task.title),el("p","",task.description||"No additional instructions"),el("small","",statusLabel(task.assigned_role)+" · "+statusLabel(task.status)));
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
  const draft=activeCompetition.status==="draft";
  setHidden("competitionAutoSetup",!draft||teamRows.length>0);
  setHidden("competitionManualTeamForm",!draft);
  setHidden("competitionTaskForm",!["draft","active"].includes(activeCompetition.status)||!teamRows.length);
  setHidden("competitionStartButton",!draft||teamRows.length<2);
  $("competitionStartButton").textContent="Start competition";
  $("competitionAutoSetupButton").disabled=!draft||teamRows.length>0;
  if(!draft){$("competitionSetupNote").textContent="Team assignments are locked after the competition starts."; }
  else $("competitionSetupNote").textContent="Create up to four company teams, assign each student to one team and role, then start the competition.";
 }

 async function renderStudentCompetition(){
  const {data:membership,error}=await db.from("competition_team_members").select("team_id,operational_role")
   .eq("competition_id",activeCompetition.id).eq("student_id",user.id).single();
  if(error)throw error;activeTeam=membership.team_id;activeRole=membership.operational_role;
  const {data:team,error:teamError}=await db.from("competition_teams").select("id,name,company_templates(name,industry,business_model)")
   .eq("id",activeTeam).single();
  if(teamError)throw teamError;
  $("competitionStudentTeam").textContent=team.name+" · "+team.company_templates?.name;
  $("competitionStudentRole").textContent=statusLabel(activeRole);
  const {data:tasks,error:taskError}=await db.from("competition_tasks").select("id,title,description,assigned_role,assigned_to,status,due_at,submission,review_note")
   .eq("competition_id",activeCompetition.id).eq("team_id",activeTeam).order("created_at",{ascending:false});
  if(taskError)throw taskError;
  const myTasks=(tasks||[]).filter(t=>(!t.assigned_to||t.assigned_to===user.id)&&(!t.assigned_role||t.assigned_role===activeRole));
  $("competitionStudentTasks").replaceChildren();
  if(!myTasks.length)addEmpty($("competitionStudentTasks"),"No tasks have been assigned to your role yet.");
  for(const task of myTasks){
   const card=el("article","competition-task-card");
   card.append(el("b","",task.title),el("p","",task.description),el("small","",statusLabel(task.status)+(task.due_at?" · Due "+new Date(task.due_at).toLocaleString():"")));
   if(task.review_note)card.append(el("p","competition-review-note",task.review_note));
   if(task.status==="pending"||task.status==="in_progress"||task.status==="rejected"){
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
  setHidden("competitionDecisionForm",activeCompetition.status!=="active");
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
 $("competitionTaskForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionTaskButton");btn.disabled=true;
  try{const {error}=await db.rpc("create_competition_task",{p_competition_id:activeCompetition.id,p_team_id:$("competitionTaskTeam").value,p_title:$("competitionTaskTitle").value.trim(),p_description:$("competitionTaskDescription").value.trim(),p_assigned_to:null,p_assigned_role:$("competitionTaskRole").value,p_priority:$("competitionTaskPriority").value,p_due_at:$("competitionTaskDue").value?new Date($("competitionTaskDue").value).toISOString():null});if(error)throw error;
   $("competitionTaskForm").reset();say("Task assigned to the selected team role.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionStartButton").addEventListener("click",async()=>{
  const btn=$("competitionStartButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("set_competition_status",{p_competition_id:activeCompetition.id,p_status:"active"});if(error)throw error;say("Competition started. Students can now work.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionDecisionForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionDecisionButton");btn.disabled=true;
  try{const {error}=await db.rpc("record_competition_decision",{p_competition_id:activeCompetition.id,p_team_id:activeTeam,p_domain:$("competitionDecisionDomain").value,p_decision_type:$("competitionDecisionType").value.trim(),p_selected_option:$("competitionDecisionOption").value.trim(),p_rationale:$("competitionDecisionRationale").value.trim(),p_inputs:{role:activeRole}});if(error)throw error;
   $("competitionDecisionForm").reset();say("Your decision was recorded.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 db.auth.getSession().then(({data})=>initialize(data.session));
 db.auth.onAuthStateChange((_event,session)=>{if(session)setTimeout(()=>initialize(session),0);else{root.hidden=true;user=null;activeCompetition=null;}});
}
