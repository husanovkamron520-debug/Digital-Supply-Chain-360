import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root=document.querySelector("#competitionWorkspace");
if(root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")){
 const db=createClient(SUPABASE_URL,SUPABASE_ANON_KEY);
 const $=id=>document.getElementById(id);
 const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;};
 const option=(label,value)=>{const n=el("option","",label);n.value=value;return n;};
 const roles=["procurement","manufacturer","warehouse","transport","operations","supplier","retailer","customer","finance","analyst"];
 let user=null,isTeacher=false,classrooms=[],templates=[],activeClassId=null,activeCompetition=null,activeTeam=null,activeRole=null,amazonRoundTimerInterval=null;

 function say(message,success=false){$("competitionMessage").textContent=message;$("competitionMessage").classList.toggle("success",success);}
 function statusLabel(value){if(value==="manufacturer")return "FULFILLMENT OPERATIONS MANAGER";return (value||"").replaceAll("_"," ").toUpperCase();}
 const isAmazonCase=()=>activeCompetition?.settings?.case_code==="amazon-global-combined-crisis";
 async function requestAiGrade(taskId,button){
  if(button)button.disabled=true;
  try{
   const {data,error}=await db.functions.invoke("competition-ai-grade",{body:{task_id:taskId}});
   if(error)throw error;
   if(data?.error)throw new Error(data.error);
   say("AI dastlabki bahosi: "+Number(data.score).toFixed(1)+"/100. O‘qituvchi tasdig‘ini kutmoqda.",true);
   await loadCompetition();
  }catch(err){
   say("AI baholash: "+(err.message||"Noma’lum xatolik"));
   if(button)button.disabled=false;
  }
 }
 function appendAiGrade(card,task){
  if(!task.ai_grade)return;
  const grade=task.ai_grade;
  const panel=el("section","competition-review-note");
  panel.append(el("b","","🤖 AI dastlabki bahosi: "+Number(grade.score??task.score??0).toFixed(1)+"/100"));
  if(grade.summary)panel.append(el("p","",grade.summary));
  if(Array.isArray(grade.criteria)){
   const list=el("ul","competition-ai-criteria");
   for(const item of grade.criteria){
    const li=el("li","",item.name+": "+item.awarded_points+"/"+item.max_points+" — "+(item.feedback||""));
    list.append(li);
   }
   panel.append(list);
  }
  if(grade.status==="ai_graded_pending_teacher_review")panel.append(el("small","","AI natijasi hali yakuniy emas — o‘qituvchi tasdiqlashi yoki o‘zgartirishi mumkin."));
  card.append(panel);
 }
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
 function formatSimulationMoney(value){
  const amount=Number(value||0);
  return (amount<0?"−":"")+Math.abs(amount).toLocaleString(undefined,{maximumFractionDigits:0})+" USD";
 }
 function formatSimulationPct(value){
  return value===null||value===undefined?"—":Number(value).toFixed(1)+"%";
 }
 function renderFinalReport(host,rows){
  host.replaceChildren();
  if(!rows?.length){addEmpty(host,"Yakuniy moliyaviy hisobot uchun ma’lumot topilmadi.");return;}
  for(const report of rows){
   const card=el("article","competition-task-card");
   const head=el("div","competition-card-head");
   const identity=el("div");
   identity.append(
    el("b","",report.team_name+" · "+report.company_name),
    el("small","","Yakuniy jamoa bahosi: "+Number(report.total_score||0).toFixed(1)+"/100 · Ma’lumot qamrovi "+Number(report.score_coverage_pct||0).toFixed(0)+"%")
   );
   const profit=el("strong",Number(report.operating_profit)>=0?"positive":"negative",formatSimulationMoney(report.operating_profit));
   head.append(identity,profit);
   card.append(head);
   const grid=el("div","competition-metric-grid");
   const metrics=[
    ["Jami tushum",formatSimulationMoney(report.revenue)],
    ["Operatsion xarajatlar",formatSimulationMoney(report.operating_cost)],
    ["Operatsion foyda",formatSimulationMoney(report.operating_profit)],
    ["Foyda marjasi",formatSimulationPct(report.profit_margin_pct)],
    ["Boshlang‘ich kapitalga ROI",formatSimulationPct(report.return_on_capital_pct)],
    ["Yakuniy pul qoldig‘i",formatSimulationMoney(report.cash_balance)],
    ["OTIF — vaqtida yetkazish",formatSimulationPct(report.service_score)],
    ["Inventar salomatligi",formatSimulationPct(report.inventory_score)],
    ["O‘rtacha yetkazish muddati",report.avg_delivery_days===null?"—":Number(report.avg_delivery_days).toFixed(1)+" kun"],
    ["Yetkazilgan buyurtmalar",Number(report.delivered_orders||0)+" / "+Number(report.total_orders||0)]
   ];
   for(const [label,value] of metrics){
    const item=el("div","competition-metric");
    item.append(el("span","",label),el("strong","",value));
    grid.append(item);
   }
   card.append(grid);
   card.append(el("small","form-hint","Hisoblash: operatsion foyda = tushum − simulyatsiyada qayd etilgan xarajatlar; foyda marjasi = foyda / tushum; ROI = foyda / boshlang‘ich kapital. Bu o‘quv simulyatsiyasi hisoboti, auditdan o‘tgan moliyaviy hisobot emas."));
   host.append(card);
  }
 }
 function setHidden(id,value){$(id).hidden=value;}

 const telegramGenerateButton=$("telegramLinkGenerateButton");
 if(telegramGenerateButton){
  telegramGenerateButton.addEventListener("click",async()=>{
   telegramGenerateButton.disabled=true;
   try{
    const bytes=crypto.getRandomValues(new Uint8Array(24));
    const code=Array.from(bytes,b=>b.toString(16).padStart(2,"0")).join("");
    const {data,error}=await db.rpc("create_telegram_link_code",{p_code:code});
    if(error)throw error;
    $("telegramLinkCode").textContent=code;
    $("telegramLinkResult").hidden=false;
    telegramGenerateButton.textContent="Yangi kod yaratish";
    say("Bir martalik ulash kodi tayyor. Uni botga yuboring.",true);
   }catch(err){say("Telegram kodini yaratib bo‘lmadi: "+err.message);}
   finally{telegramGenerateButton.disabled=false;}
  });
  $("telegramLinkCopyButton").addEventListener("click",async()=>{
   try{await navigator.clipboard.writeText($("telegramLinkCode").textContent);$("telegramLinkCopyButton").textContent="Nusxalandi ✓";}
   catch(err){say("Kodni bosib ushlab nusxalashingiz mumkin.");}
  });
 }

 function renderLiveChallenges(challenges){
  const host=$("competitionLiveChallenges");if(!host)return;host.replaceChildren();
  if(!challenges.length){addEmpty(host,"No live exceptions. Complete a preventive risk review before the next round.");return;}
  for(const challenge of challenges.slice(0,4)){
   const card=el("article","competition-challenge-card");
   const head=el("div","competition-challenge-head");
   head.append(el("b","",challenge.title),el("span","competition-challenge-severity",challenge.severity));
   card.append(head,el("p","",challenge.prompt));
   if(challenge.evidence)card.append(el("small","",challenge.evidence));
   const btn=el("button","secondary-button","Use in decision");btn.type="button";
   btn.addEventListener("click",()=>{
    $("competitionDecisionDomain").value=challenge.domain;
    $("competitionDecisionType").value=challenge.title.slice(0,80);
    $("competitionDecisionRationale").placeholder="Address this live exception: "+challenge.prompt;
    say("Live challenge added to your decision form.",true);
    $("competitionDecisionForm").scrollIntoView({behavior:"smooth",block:"start"});
   });
   card.append(btn);host.append(card);
  }
 }

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
  setHidden("competitionList",true);setHidden("competitionCreateForm",!isTeacher);
  activeClassId=classrooms[0].id;$("competitionClassSelect").value=activeClassId;
  await loadCompetitions();
 }

 async function loadTemplates(){
  const {data,error}=await db.from("company_templates").select("id,name,industry,business_model,case_study_note,source_urls").in("slug",["omnichannel-retail","amazon-global-combined-crisis"]).order("name");
  if(error)throw error;templates=data||[];
  $("competitionTemplateSelect").replaceChildren(...templates.map(t=>option((t.slug==="amazon-global-combined-crisis"?"Amazon Global Combined Crisis":"Amazon · Legacy case")+" · "+t.industry,t.id)));
 }

 async function loadCompetitions(){
  if(!activeClassId)return;
  const {data,error}=await db.from("competitions").select("id,title,status,created_at,starts_at,settings")
   .eq("classroom_id",activeClassId).order("created_at",{ascending:false});
  if(error)throw error;
  let rows=data||[];
  const classroomCompetitions=rows;
  if(!isTeacher){
   const eligible=[];
   for(const comp of classroomCompetitions.filter(c=>["active","paused"].includes(c.status))){
    const {data:membership,error:memberError}=await db.from("competition_team_members").select("id,team_id,operational_role")
     .eq("competition_id",comp.id).eq("student_id",user.id).maybeSingle();
    if(memberError)throw memberError;
    if(membership)eligible.push({...comp,membership});
   }
   rows=eligible;
  }
  $("competitionSelect").replaceChildren(...rows.map(c=>option(c.title+" · "+statusLabel(c.status),c.id)));
  if(!rows.length){
   activeCompetition=null;
   const emptyOption=option(isTeacher?"No competitions yet":"No assigned competition yet","");
   emptyOption.disabled=true;$("competitionSelect").append(emptyOption);$("competitionSelect").value="";
   setHidden("competitionWorkspaceEmpty",false);setHidden("competitionManager",true);setHidden("competitionList",false);
   setHidden("competitionStudentPanel",true);setHidden("competitionTeacherPanel",!isTeacher);
   const draftCount=classroomCompetitions.filter(c=>c.status==="draft").length;
   const studentMessage=draftCount
    ?draftCount+" draft competition(s) exist in this classroom, but your teacher has not assigned you to a team and started one yet. Ask your teacher to finish team setup and start the competition."
    :"No active competition has been assigned to you yet. Your teacher must create teams, assign you to a team, and start the competition.";
   addEmpty($("competitionList"),isTeacher?"No competition yet. Create one to begin.":studentMessage);
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
  if($("competitionTemplateSelect")){const desiredSlug=comp.settings?.case_code==="amazon-global-combined-crisis"?"amazon-global-combined-crisis":"omnichannel-retail";const template=templates.find(t=>t.slug===desiredSlug);if(template)$("competitionTemplateSelect").value=template.id;}
  setHidden("competitionManager",false);
  $("competitionCurrentTitle").textContent=comp.title;
  $("competitionCurrentStatus").textContent=statusLabel(comp.status);
  setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
  if(isTeacher)await renderTeacherCompetition();else await renderStudentCompetition();
 }

 async function renderTeacherCompetition(){
  const [{data:teams,error:teamError},{data:students,error:studentError},{data:tasks,error:taskError},{data:decisions,error:decisionError},{data:allMemberRows,error:memberError}]=await Promise.all([
   db.from("competition_teams").select("id,name,company_template_id,company_templates(name,industry,business_model,case_study_note,source_urls)").eq("competition_id",activeCompetition.id).order("created_at"),
   db.from("classroom_members").select("student_id,profiles(full_name)").eq("classroom_id",activeClassId).order("joined_at"),
   db.from("competition_tasks").select("id,team_id,title,description,assigned_role,assigned_to,status,due_at,due_round,submitted_round,submission,review_note,score,feedback,ai_grade,ai_graded_at,ai_model").eq("competition_id",activeCompetition.id).order("created_at",{ascending:false}),
   db.from("competition_decisions").select("id,team_id,student_id,domain,decision_type,selected_option,rationale,inputs,score,feedback,created_at,profiles(full_name)").eq("competition_id",activeCompetition.id).order("created_at",{ascending:false}),
   db.from("competition_team_members").select("team_id,student_id,operational_role,profiles(full_name)").eq("competition_id",activeCompetition.id)
  ]);
  for(const e of [teamError,studentError,taskError,decisionError,memberError])if(e)throw e;
  const teamRows=teams||[],studentRows=students||[],taskRows=tasks||[],decisionRows=decisions||[];
  const recommendedTeamCount=Math.max(2,Math.min(4,Math.floor(studentRows.length/5)));
  $("competitionTeamCount").value=String(recommendedTeamCount);
  $("competitionTeamCount").dataset.studentCount=String(studentRows.length);
  for(const opt of $("competitionTeamCount").options)opt.disabled=studentRows.length<Number(opt.value)*5;
  $("competitionTeamCount").disabled=studentRows.length<10;
  $("competitionTeams").replaceChildren();
  let assignedStudentCount=0;const teamSizes=[];let allTeamsReady=teamRows.length>=2&&teamRows.length<=4;
  const coreRoles=["procurement","supplier","manufacturer","warehouse","transport"];
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
    const teamMembers=members||[];assignedStudentCount+=teamMembers.length;teamSizes.push(teamMembers.length);
    const presentRoles=new Set(teamMembers.map(member=>member.operational_role));
    const missingRoles=coreRoles.filter(role=>!presentRoles.has(role));
    const teamReady=teamMembers.length>=5&&missingRoles.length===0;
    if(!teamReady)allTeamsReady=false;
    head.lastChild.textContent=presentRoles.size+"/5 core roles";
    const readiness=el("small","competition-readiness",teamReady
      ?"Ready · "+teamMembers.length+" students"
      :"Needs "+(missingRoles.length?missingRoles.map(statusLabel).join(", "):"")+" "+(teamMembers.length<5?"· "+(5-teamMembers.length)+" more student(s)":""));
    const list=el("div","competition-member-list");
    for(const member of teamMembers){
     const line=el("div","competition-member-line");
     const identity=el("div","competition-member-identity");
     identity.append(el("span","",member.profiles?.full_name||"Student"),el("small","",statusLabel(member.operational_role)));
     line.append(identity);
     if(activeCompetition.status==="draft"){
      const edit=el("button","secondary-button","Edit");edit.type="button";
      const form=el("form","competition-member-edit");form.hidden=true;
      const teamSelect=el("select","");teamSelect.setAttribute("aria-label","Assign team for "+(member.profiles?.full_name||"student"));
      for(const target of teamRows)teamSelect.append(option(target.name,target.id));
      teamSelect.value=team.id;
      const roleSelect=el("select","");roleSelect.setAttribute("aria-label","Assign role for "+(member.profiles?.full_name||"student"));
      for(const role of roles)roleSelect.append(option(statusLabel(role),role));
      roleSelect.value=member.operational_role;
      const save=el("button","secondary-button","Save assignment");save.type="submit";
      form.append(teamSelect,roleSelect,save);
      edit.addEventListener("click",()=>{form.hidden=!form.hidden;edit.textContent=form.hidden?"Edit":"Cancel";});
      form.addEventListener("submit",async e=>{
       e.preventDefault();save.disabled=true;
       try{
        const {error}=await db.rpc("update_competition_member_assignment",{p_membership_id:member.id,p_target_team_id:teamSelect.value,p_operational_role:roleSelect.value});
        if(error)throw error;say("Student team and role updated.",true);await loadCompetition();
       }catch(err){say(err.message);save.disabled=false;}
      });
      line.append(edit);list.append(line,form);
     }else list.append(line);
    }
    card.append(readiness,list);
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
   const assignedMember=(allMemberRows||[]).find(m=>m.student_id===task.assigned_to&&m.team_id===task.team_id);
   const assignedTeam=teamRows.find(t=>t.id===task.team_id);
   card.append(el("div","competition-card-head",task.title),el("p","competition-task-description",task.description||"No additional instructions"),el("small","", (assignedTeam?.name||"Team")+" · "+(assignedMember?.profiles?.full_name||"Unassigned student")+" · "+statusLabel(task.assigned_role)+" · "+statusLabel(task.status)+(task.due_round?" · Due round "+task.due_round:"")+(task.submitted_round?" · Submitted round "+task.submitted_round:"")+(task.due_round&&task.submitted_round>task.due_round?" · LATE":"")));
   if(task.submission)card.append(el("pre","competition-submission",typeof task.submission.response==="string"?task.submission.response:JSON.stringify(task.submission,null,2)));
   appendAiGrade(card,task);
   if(task.score!==null&&task.score!==undefined)card.append(el("p","competition-review-note","Teacher score: "+Number(task.score).toFixed(1)+"/100 · "+(task.feedback||task.review_note||"")));
   if(task.status==="submitted"){
    const review=el("form","competition-review");
    const score=el("input","");score.type="number";score.min="0";score.max="100";score.step="1";score.required=true;score.placeholder="Task score /100";if(task.ai_grade)score.value=String(task.ai_grade.score??task.score??"");
    const note=el("textarea","");note.rows=2;note.maxLength=2000;note.placeholder="Feedback: strengths, calculation errors and improvement advice";if(task.ai_grade)note.value=String(task.ai_grade.summary||"AI dastlabki bahosi: "+task.ai_grade.score+"/100");
    const approve=el("button","secondary-button","Save score & approve");approve.type="submit";
    const reject=el("button","secondary-button","Request changes");reject.type="button";
    review.append(score,note,approve,reject);
    review.addEventListener("submit",async e=>{
     e.preventDefault();approve.disabled=true;
     try{const {error}=await db.rpc("evaluate_competition_task",{p_task_id:task.id,p_score:Number(score.value),p_feedback:note.value.trim()});if(error)throw error;say("Task graded and approved.",true);await loadCompetition();}
     catch(err){say(err.message);approve.disabled=false;}
    });
    reject.addEventListener("click",async()=>{
     reject.disabled=true;try{const {error}=await db.rpc("review_competition_task",{p_task_id:task.id,p_approved:false,p_review_note:note.value.trim()});if(error)throw error;say("Changes requested.",true);await loadCompetition();}catch(err){say(err.message);reject.disabled=false;}
    });
    card.append(review);
   }
   $("competitionTaskList").append(card);
  }
  $("competitionDecisionList").replaceChildren();
  if(!decisionRows.length)addEmpty($("competitionDecisionList"),"No decisions submitted yet.");
  for(const d of decisionRows){
   const card=el("article","competition-decision-card");
   card.append(el("b","",d.profiles?.full_name||"Student"),el("p","",statusLabel(d.domain)+" · "+d.selected_option),el("p","","Rationale: "+d.rationale));
   if(d.inputs?.calculations)card.append(el("p","", "Calculations: "+d.inputs.calculations));
   if(d.inputs?.risk_mitigation)card.append(el("p","", "Risks & mitigation: "+d.inputs.risk_mitigation));
   if(d.inputs?.expected_impact)card.append(el("p","", "Expected KPI impact: "+d.inputs.expected_impact));
   if(d.score!==null)card.append(el("strong","",d.score+"/100 · "+(d.feedback||"Evaluated")));
   else{
    const form=el("form","competition-rubric-form");
    const criteria=[["Quantitative accuracy",30],["Feasibility",25],["Cost / service / risk trade-off",20],["Cross-functional impact",15],["Evidence and clarity",10]];
    const scoreInputs=[];
    for(const [label,max] of criteria){
     const field=el("label","competition-rubric-field");
     field.append(el("span","",label+" / "+max));
     const input=el("input","");input.type="number";input.min="0";input.max=String(max);input.step="1";input.required=true;input.placeholder="0–"+max;
     scoreInputs.push(input);field.append(input);form.append(field);
    }
    const total=el("strong","competition-rubric-total","Total: — / 100");
    const feedback=el("input","");feedback.placeholder="Feedback and improvement advice (optional)";
    const submit=el("button","secondary-button","Save rubric score");submit.type="submit";
    const updateTotal=()=>{const complete=scoreInputs.every(input=>input.value!=="");const value=scoreInputs.reduce((sum,input)=>sum+(Number(input.value)||0),0);total.textContent=complete?"Total: "+value+" / 100":"Total: — / 100";submit.disabled=!complete||scoreInputs.some((input,index)=>Number(input.value)>criteria[index][1]||Number(input.value)<0);};
    scoreInputs.forEach(input=>input.addEventListener("input",updateTotal));
    form.append(total,feedback,submit);
    updateTotal();
    form.addEventListener("submit",async e=>{
     e.preventDefault();const value=scoreInputs.reduce((sum,input)=>sum+Number(input.value),0);submit.disabled=true;
     const breakdown=criteria.map((item,index)=>item[0]+": "+scoreInputs[index].value+"/"+item[1]).join(" · ");
     const note=[breakdown,feedback.value.trim()].filter(Boolean).join(" | ");
     try{const {error}=await db.rpc("evaluate_competition_decision",{p_decision_id:d.id,p_score:value,p_feedback:note});if(error)throw error;say("Decision evaluated with the five-part rubric.",true);await loadCompetition();}
     catch(err){say(err.message);submit.disabled=false;}
    });
    card.append(form);
   }
   $("competitionDecisionList").append(card);
  }
  const {data:metricRows,error:metricError}=await db.from("competition_team_live_metrics").select("*").eq("competition_id",activeCompetition.id).order("total_score",{ascending:false});
  if(metricError)throw metricError;
  const finalReportWrap=$("competitionFinalReportsWrap");
  if(activeCompetition.status==="completed"){
   const {data:finalReports,error:finalReportError}=await db.rpc("get_competition_final_report",{p_competition_id:activeCompetition.id});
   if(finalReportError)throw finalReportError;
   setHidden("competitionFinalReportsWrap",false);
   renderFinalReport($("competitionFinalReports"),finalReports||[]);
  }else{
   setHidden("competitionFinalReportsWrap",true);
   $("competitionFinalReports").replaceChildren();
  }
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
  const individuals=new Map(),roleOwners=new Map();
  for(const member of allMemberRows||[]){
   const key=member.team_id+"|"+member.operational_role;
   const current=roleOwners.get(key)||{count:0,student_id:null};
   current.count++;current.student_id=member.student_id;roleOwners.set(key,current);
  }
  const ensureIndividual=(studentId,teamId,name)=>{
   const key=studentId+"|"+teamId;
   if(!individuals.has(key))individuals.set(key,{name:name||"Student",decisionScores:[],taskScores:[],decisionSubmitted:0,decisionEvaluated:0,taskSubmitted:0,taskEvaluated:0});
   return individuals.get(key);
  };
  for(const d of decisionRows){
   const item=ensureIndividual(d.student_id,d.team_id,d.profiles?.full_name);
   item.decisionSubmitted++;if(d.score!==null){item.decisionEvaluated++;item.decisionScores.push(Number(d.score));}
  }
  for(const task of taskRows){
   const owner=task.assigned_to?{count:1,student_id:task.assigned_to}:roleOwners.get(task.team_id+"|"+task.assigned_role);
   if(!owner||owner.count!==1||!owner.student_id)continue;
   const member=(allMemberRows||[]).find(m=>m.student_id===owner.student_id&&m.team_id===task.team_id);
   const item=ensureIndividual(owner.student_id,task.team_id,member?.profiles?.full_name);
   item.taskSubmitted++;if(task.score!==null&&task.score!==undefined){item.taskEvaluated++;item.taskScores.push(Number(task.score));}
  }
  $("competitionIndividualRanking").replaceChildren();
  const ranked=[...individuals.values()].filter(x=>x.decisionScores.length||x.taskScores.length).map(x=>{
   const decisionAverage=x.decisionScores.length?x.decisionScores.reduce((a,b)=>a+b,0)/x.decisionScores.length:null;
   const taskAverage=x.taskScores.length?x.taskScores.reduce((a,b)=>a+b,0)/x.taskScores.length:null;
   const average=decisionAverage!==null&&taskAverage!==null?(decisionAverage+taskAverage)/2:(decisionAverage??taskAverage);
   return {...x,decisionAverage,taskAverage,average};
  }).sort((a,b)=>b.average-a.average);
  if(!ranked.length)addEmpty($("competitionIndividualRanking"),"Individual ranking appears after task and decision evaluations.");
  for(const [index,p] of ranked.entries()){
   const evidence=p.decisionEvaluated+" decision(s) + "+p.taskEvaluated+" case task(s) graded";
   const submitted=p.decisionSubmitted+" decision(s) + "+p.taskSubmitted+" task(s) submitted";
   const split="Decision avg "+(p.decisionAverage===null?"—":p.decisionAverage.toFixed(1))+" · Case avg "+(p.taskAverage===null?"—":p.taskAverage.toFixed(1))+" · 50/50";
   const row=el("article","competition-score-row");row.append(el("b","",(index+1)+". "+p.name+" · "+evidence),el("small","",split),el("small","",submitted),el("strong","",p.decisionAverage!==null&&p.taskAverage!==null?p.average.toFixed(1)+"/100":"In progress"));
   $("competitionIndividualRanking").append(row);
  }
    const {data:clock,error:clockError}=await db.from("competition_simulation_clock").select("current_round,round_limit,virtual_now").eq("competition_id",activeCompetition.id).maybeSingle();
  if(clockError)throw clockError;
  let roundWindow=null;
  if(clock&&isAmazonCase()){const rw=await db.from("competition_rounds").select("ends_at").eq("competition_id",activeCompetition.id).eq("round_number",clock.current_round).maybeSingle();if(rw.error)throw rw.error;roundWindow=rw.data;}
  const roundStillRunning=!!(roundWindow?.ends_at&&new Date(roundWindow.ends_at).getTime()>Date.now());
  $("competitionRoundInfo").textContent=clock?(isAmazonCase()?"Round "+clock.current_round+" / 3 · Day "+((clock.current_round-1)*10+1)+"–"+(clock.current_round*10)+" · 10 min/round · "+(roundWindow?.ends_at?"Tugash vaqti "+new Date(roundWindow.ends_at).toLocaleTimeString():""):"Round "+clock.current_round+" / "+clock.round_limit+" · Simulation date "+new Date(clock.virtual_now).toLocaleDateString()):"Rounds begin when the competition starts.";
  setHidden("competitionAdvanceRound",activeCompetition.status!=="active");
  $("competitionAdvanceRound").disabled=!clock||clock.current_round>=clock.round_limit||(isAmazonCase()&&roundStillRunning);
  if(amazonRoundTimerInterval){clearInterval(amazonRoundTimerInterval);amazonRoundTimerInterval=null;}
  if(isAmazonCase()&&roundWindow?.ends_at){
   const endsAt=new Date(roundWindow.ends_at).getTime();
   const updateRoundTimer=()=>{const remaining=Math.max(0,endsAt-Date.now());const mm=String(Math.floor(remaining/60000)).padStart(2,"0");const ss=String(Math.floor((remaining%60000)/1000)).padStart(2,"0");
    $("competitionRoundInfo").textContent="Round "+clock.current_round+" / 3 · Day "+((clock.current_round-1)*10+1)+"–"+(clock.current_round*10)+" · Qolgan vaqt "+mm+":"+ss;
    $("competitionAdvanceRound").disabled=remaining>0||clock.current_round>=3;
    if(remaining===0&&amazonRoundTimerInterval){clearInterval(amazonRoundTimerInterval);amazonRoundTimerInterval=null;}
   };
   updateRoundTimer();if(roundStillRunning)amazonRoundTimerInterval=setInterval(updateRoundTimer,1000);
  }
  const pendingDecisionCount=decisionRows.filter(d=>d.score===null).length;
  const studentsWithoutDecision=allMemberRows.filter(m=>!decisionRows.some(d=>d.student_id===m.student_id&&d.team_id===m.team_id&&d.score!==null)).length;
  const pendingTaskCount=taskRows.filter(task=>task.status!=="approved"||task.score===null||task.score===undefined).length;
  const studentsWithoutTask=allMemberRows.filter(m=>!taskRows.some(task=>task.assigned_to===m.student_id&&task.team_id===m.team_id&&task.score!==null&&task.score!==undefined)).length;
  setHidden("competitionCompleteButton",activeCompetition.status!=="active"||!clock||clock.current_round<clock.round_limit);
  $("competitionCompleteButton").disabled=pendingDecisionCount>0||studentsWithoutDecision>0||pendingTaskCount>0||studentsWithoutTask>0||taskRows.length===0;
  $("competitionCompleteButton").textContent=taskRows.length===0
   ?"Generate role case tasks first"
   :pendingDecisionCount>0
    ?"Evaluate "+pendingDecisionCount+" pending decision(s) first"
    :studentsWithoutDecision>0
     ?"Collect and grade a decision from "+studentsWithoutDecision+" student(s)"
     :pendingTaskCount>0||studentsWithoutTask>0
      ?"Grade or request resubmission for "+Math.max(pendingTaskCount,studentsWithoutTask)+" case task(s)"
      :"Complete competition & finalise results";
  const draft=activeCompetition.status==="draft";
  setHidden("competitionAutoSetup",!draft||teamRows.length>0);
  setHidden("competitionManualTeamForm",!draft);
  setHidden("competitionTaskForm",!["draft","active"].includes(activeCompetition.status)||!teamRows.length);
  setHidden("competitionTaskPackButton",!["draft","active"].includes(activeCompetition.status)||!teamRows.length||taskRows.length>0);
  const sizeBalanced=teamSizes.length>0&&Math.max(...teamSizes)-Math.min(...teamSizes)<=1;
  const everyStudentAssigned=assignedStudentCount===studentRows.length;
  const readyToStart=allTeamsReady&&sizeBalanced&&everyStudentAssigned;
  setHidden("competitionStartButton",!draft||teamRows.length<2);
  $("competitionStartButton").textContent="Start competition";
  $("competitionStartButton").disabled=!readyToStart;
  setHidden("competitionPauseButton",!["active","paused"].includes(activeCompetition.status));
  $("competitionPauseButton").textContent=activeCompetition.status==="paused"?"Resume competition":"Pause competition";
  $("competitionAutoSetupButton").disabled=!draft||teamRows.length>0||studentRows.length<10;
  setHidden("competitionManualTeamForm",!draft||teamRows.length>=4);
  if(!draft){$("competitionSetupNote").textContent="Teams are locked after the competition starts."; }
  else $("competitionSetupNote").textContent=isAmazonCase()
   ?(studentRows.length<10
    ?"Amazon case uchun kamida 10 o‘quvchi kerak (2 jamoa × 5 rol). Hozir: "+studentRows.length+"."
    :"Amazon case: "+recommendedTeamCount+" jamoa tavsiya etiladi. Har bir jamoada 5 ta alohida rol bo‘ladi.")
   :(studentRows.length<10
    ?"Only "+studentRows.length+" students are enrolled. At least 10 are required to create two valid teams."
    :"Recommended setup: "+recommendedTeamCount+" teams for "+studentRows.length+" enrolled students. Each team needs at least 5 students and all 5 core roles.");
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
  const {data:tasks,error:taskError}=await db.from("competition_tasks").select("id,title,description,assigned_role,assigned_to,status,due_at,due_round,submitted_round,submission,review_note,score,feedback,ai_grade,ai_graded_at,ai_model")
   .eq("competition_id",activeCompetition.id).eq("team_id",activeTeam).order("created_at",{ascending:false});
  if(taskError)throw taskError;
  const myTasks=(tasks||[]).filter(t=>(!t.assigned_to||t.assigned_to===user.id)&&(!t.assigned_role||t.assigned_role===activeRole));
  $("competitionStudentTasks").replaceChildren();
  if(!myTasks.length)addEmpty($("competitionStudentTasks"),"No tasks have been assigned to your role yet.");
  for(const task of myTasks){
   const card=el("article","competition-task-card");
   card.append(el("b","",task.title),el("p","competition-task-description",task.description),el("small","",statusLabel(task.status)+(task.due_round?" · Due round "+task.due_round:"")+(task.due_at?" · Due "+new Date(task.due_at).toLocaleString():"")+(task.due_round&&task.submitted_round>task.due_round?" · LATE":"")));
   if(task.review_note)card.append(el("p","competition-review-note",task.review_note));
   appendAiGrade(card,task);
   if(["pending","in_progress","rejected"].includes(task.status)&&activeCompetition.status==="active"){
    const form=el("form","competition-submit-form");
    const answer=el("textarea","");answer.rows=3;answer.maxLength=10000;answer.placeholder="Describe your work, calculations and evidence…";answer.required=true;
    const btn=el("button","primary-button","Submit task");btn.type="submit";
    form.append(answer,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("submit_competition_task",{p_task_id:task.id,p_submission:{response:answer.value.trim(),role:activeRole,submitted_at:new Date().toISOString()}});if(error)throw error;say("Javob yuborildi. AI baholashi boshlanmoqda…",true);await loadCompetition();await requestAiGrade(task.id,null);}catch(err){say(err.message);btn.disabled=false;}});
    card.append(form);
   }else if(task.submission){
    card.append(el("pre","competition-submission",JSON.stringify(task.submission,null,2)));
    if(task.status==="submitted"&&!task.ai_graded_at){
     const gradeBtn=el("button","secondary-button","🤖 AI orqali baholash");gradeBtn.type="button";
     gradeBtn.addEventListener("click",()=>requestAiGrade(task.id,gradeBtn));
     card.append(gradeBtn);
    }
   }
   $("competitionStudentTasks").append(card);
  }
  const {data:decisions,error:decisionError}=await db.from("competition_decisions").select("domain,selected_option,rationale,inputs,score,feedback,created_at")
   .eq("competition_id",activeCompetition.id).eq("student_id",user.id).order("created_at",{ascending:false});
  if(decisionError)throw decisionError;
  $("competitionStudentDecisionHistory").replaceChildren();
  if(!decisions?.length)addEmpty($("competitionStudentDecisionHistory"),"Your decision history will appear here.");
  for(const d of decisions||[]){
   const row=el("article","competition-decision-card");
   row.append(el("b","",statusLabel(d.domain)+" · "+d.selected_option),el("p","",d.rationale));
   if(d.inputs?.calculations)row.append(el("p","", "Calculations: "+d.inputs.calculations));
   if(d.inputs?.risk_mitigation)row.append(el("p","", "Risks & mitigation: "+d.inputs.risk_mitigation));
   if(d.inputs?.expected_impact)row.append(el("p","", "Expected KPI impact: "+d.inputs.expected_impact));
   row.append(el("small","",d.score===null?"Awaiting evaluation":"Score "+d.score+"/100 · "+(d.feedback||"")));
   $("competitionStudentDecisionHistory").append(row);
  }
  await loadTeamOperations();
  await loadPublicCompetitionResults();
  setHidden("competitionDecisionForm",activeCompetition.status!=="active");
 }



 async function renderAmazonCasePanel(teamId,clock){
  const {data:caseData,error:caseError}=await db.rpc("amazon_get_case_data",{p_team_id:teamId});
  if(caseError)throw caseError;
  const [{data:orders,error:ordersError},{data:inventory,error:inventoryError},{data:pos,error:poError},{data:shipments,error:shipError}]=await Promise.all([
   db.from("competition_customer_orders").select("id,order_number,sku,item_name,quantity,unit_price,status,due_at").eq("team_id",teamId).order("due_at"),
   db.from("competition_inventory").select("sku,item_name,quantity,item_type").eq("team_id",teamId).order("sku"),
   db.from("competition_purchase_orders").select("id,po_number,sku,item_name,quantity,received_quantity,unit_cost,status,expected_at,available_at,supplier_id").eq("team_id",teamId).order("created_at",{ascending:false}),
   db.from("competition_shipments").select("id,order_id,quantity,status,eta,destination,carrier").eq("team_id",teamId).order("dispatched_at",{ascending:false})
  ]);
  for(const e of [ordersError,inventoryError,poError,shipError])if(e)throw e;
  let host=$("amazonCasePanel");
  if(!host){host=el("section","competition-setup");host.id="amazonCasePanel";$("competitionStudentPanel").append(host);}
  host.replaceChildren();
  const state=caseData.state||{},skus=caseData.skus||[],offers=caseData.offers||[],fulfilment=caseData.fulfilment||[],approvals=caseData.approvals||[],commitments=caseData.commitments||[],qualityReceipts=caseData.quality_receipts||[];
  const round=Number(clock.current_round),day=(round-1)*10+1;
  const header=el("div","competition-panel-heading");
  header.append(el("h3","","Amazon Global Combined Crisis"),el("p","","30 kunlik global e-commerce inqirozi · Round "+round+"/3 · Day "+day+"–"+(day+9)+" · 10 real minutes per round"));
  host.append(header);
  const summary=el("div","competition-metric-grid");
  const summaryValues=[
   ["Asosiy xarid budjeti","$"+Number(state.main_budget||160000).toLocaleString()],
   ["Favqulodda rezerv","$"+Number(state.reserve_budget||30000).toLocaleString()+" · tasdiq $"+Number(state.reserve_approved||0).toLocaleString()],
   ["Majburiyatga olingan xarid","$"+Number(state.committed_spend||0).toLocaleString()],
   ["Strategiya",statusLabel(state.strategic_posture)],["Ombor sig‘imi · vaqtinchalik",Number(state.warehouse_capacity_units||8000).toLocaleString()+" dona"]
  ];
  for(const [label,value] of summaryValues){const card=el("div","competition-metric");card.append(el("span","",label),el("strong","",value));summary.append(card);}
  host.append(summary);
  const demand=el("div","competition-task-card");
  demand.append(el("b","","Inqiroz ko‘rsatkichlari"),el("p","","Talab +40% · Supplier A (Xitoy) 22 kun · Supplier B (Germaniya) 8 kun · Supplier C (AQSH) 5 kun · 5 ta SKU · 9,800 dona jami talab"));
  host.append(demand);
  const stock=el("div","competition-task-card");stock.append(el("b","","Inventar holati"));
  for(const sku of skus){const item=(inventory||[]).find(x=>x.sku===sku.sku);stock.append(el("p","",sku.sku+" · "+sku.item_name+" — "+Number(item?.quantity||0).toLocaleString()+" dona / boshlang‘ich "+Number(sku.opening_stock).toLocaleString()+" · talab "+Number(sku.crisis_demand).toLocaleString()));}
  host.append(stock);

  const offersCard=el("div","competition-task-card");offersCard.append(el("b","","Supplier takliflari · MOQ · 30 kunlik quvvat"));
  for(const sku of skus){
   const line=el("p","");
   const detail=offers.filter(o=>o.sku===sku.sku).map(o=>o.supplier_code+" $"+Number(o.unit_price).toFixed(2)+" · MOQ "+o.moq+" · cap "+Number(o.max_capacity).toLocaleString()+" · "+o.lead_time_days+" kun · OTIF "+o.otif_pct+"% · defect "+o.defect_rate_pct+"%").join(" | ");
   line.textContent=sku.sku+" "+sku.item_name+": "+detail;offersCard.append(line);
  }
  host.append(offersCard);

  if(activeRole==="procurement"){
   const card=el("div","competition-task-card");card.append(el("h4","","Procurement Manager · Xarid rejasi"));
   const form=el("form","competition-inline-form");
   const supplier=el("select","");supplier.required=true;
   for(const code of ["SUP-A","SUP-B","SUP-C"])supplier.append(option(code+" · "+({ "SUP-A":"China","SUP-B":"Germany","SUP-C":"USA"}[code]),code));
   const skuSelect=el("select","");skuSelect.required=true;
   for(const sku of skus)skuSelect.append(option(sku.sku+" · "+sku.item_name,sku.sku));
   const qty=el("input","");qty.type="number";qty.min="1";qty.required=true;qty.placeholder="Quantity";
   const orderDay=el("input","");orderDay.type="number";orderDay.min=String(day);orderDay.max=String(day+9);orderDay.value=String(day);orderDay.required=true;
   const submit=el("button","secondary-button","Xarid buyurtmasini yuborish");submit.type="submit";
   form.append(supplier,skuSelect,qty,orderDay,submit);
   form.addEventListener("submit",async e=>{e.preventDefault();submit.disabled=true;try{
    const {error}=await db.rpc("amazon_place_purchase_order",{p_team_id:teamId,p_supplier_code:supplier.value,p_sku:skuSelect.value,p_quantity:Number(qty.value),p_order_day:Number(orderDay.value)});
    if(error)throw error;say("Amazon xarid buyurtmasi qabul qilindi.",true);await loadTeamOperations();
   }catch(err){say(err.message);submit.disabled=false;}});
   card.append(form);
   const postureForm=el("form","competition-inline-form");const posture=el("select","");
   posture.append(option("Balanced · A ulushi 40–70%","balanced"),option("Cost-focused · A kamida 60%","cost_focused"));
   const servicePosture=option("Service-focused · B+C kamida 60% · mavjud quvvat bilan imkonsiz","service_focused");servicePosture.disabled=true;posture.append(servicePosture);
   posture.value=state.strategic_posture||"balanced";
   card.append(el("p","form-hint","Service-focused hozircha yopiq: B+C supplierlari jami 4,000 dona bera oladi, net ehtiyoj 7,950 dona — maksimal 50.3%. 60% chegaraga yetmaydi."));
   const reason=el("input","");reason.placeholder="Strategiyani o‘zgartirish sababi";reason.required=true;
   const req=el("button","secondary-button","Strategiya o‘zgarishini tasdiqqa yuborish");req.type="submit";
   postureForm.append(posture,reason,req);
   postureForm.addEventListener("submit",async e=>{e.preventDefault();req.disabled=true;try{const {error}=await db.rpc("amazon_submit_approval",{p_team_id:teamId,p_approval_type:"strategy_change",p_reason:reason.value,p_payload:{posture:posture.value}});if(error)throw error;say("Strategiya o‘zgarishi jamoa tasdig‘iga yuborildi.",true);await loadTeamOperations();}catch(err){say(err.message);req.disabled=false;}});
   card.append(el("h4","","Strategik xarid modeli"),postureForm);
   const reserveForm=el("form","competition-inline-form");const amount=el("input","");amount.type="number";amount.min="1";amount.max="30000";amount.placeholder="Rezervdan summa (USD)";amount.required=true;
   const reserveReason=el("input","");reserveReason.placeholder="Rezerv ishlatish sababi";reserveReason.required=true;
   const reserveBtn=el("button","secondary-button","$30,000 rezervdan foydalanishga ruxsat so‘rash");reserveBtn.type="submit";
   reserveForm.append(amount,reserveReason,reserveBtn);
   reserveForm.addEventListener("submit",async e=>{e.preventDefault();reserveBtn.disabled=true;try{const {error}=await db.rpc("amazon_submit_approval",{p_team_id:teamId,p_approval_type:"reserve_draw",p_reason:reserveReason.value,p_payload:{amount:Number(amount.value)}});if(error)throw error;say("Favqulodda rezerv so‘rovi jamoaga yuborildi.",true);await loadTeamOperations();}catch(err){say(err.message);reserveBtn.disabled=false;}});
   card.append(el("h4","","Favqulodda rezerv"),reserveForm);host.append(card);
  }
  if(activeRole==="supplier"){
   const card=el("div","competition-task-card");card.append(el("h4","","Supplier Relations Manager"),el("p","","Uchta supplier bilan yetkazib berish majburiyatini tasdiqlang, A supplier kechikishini eskalatsiya qiling va B/C alternativ manbalar bilan SLA xavfini boshqaring. Bu qaydlar procurement buyurtmasi yoki zaxira yaratmaydi; real PO’ni Procurement Manager beradi."));
   const form=el("form","competition-inline-form"),supplier=el("select",""),skuSelect=el("select",""),qty=el("input",""),arrival=el("input",""),status=el("select",""),note=el("input","");
   for(const code of ["SUP-A","SUP-B","SUP-C"])supplier.append(option(code+" · "+({"SUP-A":"China","SUP-B":"Germany","SUP-C":"USA"}[code]),code));
   for(const sku of skus)skuSelect.append(option(sku.sku+" · "+sku.item_name,sku.sku));
   qty.type="number";qty.min="1";qty.placeholder="Supplier tasdiqlagan miqdor";qty.required=true;
   arrival.type="number";arrival.min="1";arrival.max="30";arrival.required=true;arrival.placeholder="Kutilayotgan yetib kelish kuni";
   status.append(option("Confirmed","confirmed"),option("At risk","at_risk"),option("Escalated","escalated"));
   note.placeholder="Supplier bilan muloqot, SLA yoki eskalatsiya tafsiloti";note.required=true;
   const btn=el("button","secondary-button","Supplier commitment qayd etish");btn.type="submit";
   form.append(supplier,skuSelect,qty,arrival,status,note,btn);
   const setArrival=()=>{const offer=offers.find(o=>o.supplier_code===supplier.value&&o.sku===skuSelect.value);const earliest=(round-1)*10+1+Number(offer?.lead_time_days||1);arrival.min=String(earliest);arrival.value=String(Math.min(30,earliest));};
   supplier.addEventListener("change",setArrival);skuSelect.addEventListener("change",setArrival);setArrival();
   form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("amazon_record_supplier_commitment",{p_team_id:teamId,p_supplier_code:supplier.value,p_sku:skuSelect.value,p_quantity:Number(qty.value),p_expected_arrival_day:Number(arrival.value),p_status:status.value,p_note:note.value});if(error)throw error;say("Supplier commitment qayd etildi.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
   card.append(form);
   card.append(el("h4","","Supplier commitments & escalations"));
   if(!commitments.length)card.append(el("p","empty-state","Hozircha supplier commitment qayd etilmagan."));
   for(const item of commitments)card.append(el("p","",item.supplier_code+" · "+item.sku+" · "+item.committed_quantity+" dona · Day "+item.expected_arrival_day+" · "+statusLabel(item.commitment_status)+" — "+item.note));
   host.append(card);
  }
  if(activeRole==="manufacturer"){
   const card=el("div","competition-task-card");card.append(el("h4","","Fulfillment Operations Manager · Pick / Pack / Release"));
   const readyMap=new Map(fulfilment.map(x=>[x.order_id,Number(x.ready_quantity)]));
   for(const order of orders.filter(o=>!["delivered","cancelled"].includes(o.status))){
    const shipped=shipments.filter(x=>x.order_id===order.id&&x.status!=="cancelled").reduce((n,x)=>n+Number(x.quantity),0);
    const ready=readyMap.get(order.id)||0;const remaining=Math.max(0,Number(order.quantity)-shipped-ready);
    const line=el("div","competition-task-card");line.append(el("b","",order.order_number+" · "+order.item_name),el("p","",order.quantity+" dona · tayyor "+ready+" · jo‘natilgan "+shipped+" · qolgan "+remaining));
    if(remaining>0&&activeCompetition.status==="active"){
     const form=el("form","competition-inline-form"),q=el("input","");q.type="number";q.min="1";q.max=String(remaining);q.value=String(remaining);q.required=true;
     const btn=el("button","secondary-button","Pick / Pack qilib transportga chiqarish");btn.type="submit";form.append(q,btn);
     form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {data,error}=await db.rpc("amazon_fulfill_order",{p_order_id:order.id,p_quantity:Number(q.value)});if(error)throw error;say("Fulfilment tayyor: "+data.ready_quantity+" dona transportga berildi.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
     line.append(form);
    }
    card.append(line);
   }
   host.append(card);
  }
  if(activeRole==="warehouse"){
   const card=el("div","competition-task-card");card.append(el("h4","","Warehouse Manager · Inbound receiving"));
   for(const po of pos.filter(p=>["placed","partially_received"].includes(p.status))){
    const available=new Date(po.available_at||po.expected_at)<=new Date(clock.virtual_now);
    const line=el("div","competition-task-card");line.append(el("b","",po.po_number+" · "+po.item_name),el("p","",po.received_quantity+"/"+po.quantity+" received · ETA "+new Date(po.available_at||po.expected_at).toLocaleDateString()));
    if(available&&activeCompetition.status==="active"){
     const btn=el("button","secondary-button","Tovarni qabul qilish");btn.type="button";btn.addEventListener("click",async()=>{btn.disabled=true;try{const {data,error}=await db.rpc("amazon_receive_purchase_order",{p_purchase_order_id:po.id,p_quantity:po.quantity-po.received_quantity});if(error)throw error;say("Omborga "+data.usable_quantity+" yaroqli dona qabul qilindi; "+data.defective_quantity+" dona defect sabab karantinga ajratildi.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
     line.append(btn);
    }
    card.append(line);
   }
   card.append(el("h4","","Quality quarantine · defect units"));
   const quarantine=qualityReceipts.filter(q=>Number(q.defective_quantity)>Number(q.disposed_quantity||0));
   if(!quarantine.length)card.append(el("p","empty-state","Quarantine’da defect mahsulot yo‘q."));
   for(const qr of quarantine){
    const remaining=Number(qr.defective_quantity)-Number(qr.disposed_quantity||0);
    const line=el("div","competition-task-card");line.append(el("b","",qr.supplier_code+" · "+qr.sku),el("p","",remaining+" dona karantinda · defect rate "+qr.defect_rate_pct+"% · received "+qr.received_quantity));
    const form=el("form","competition-inline-form"),qty=el("input",""),reason=el("input",""),btn=el("button","secondary-button","Defectni karantindan chiqarish");
    qty.type="number";qty.min="1";qty.max=String(remaining);qty.value=String(remaining);qty.required=true;
    reason.placeholder="Disposal yoki supplier return sababi";reason.required=true;btn.type="submit";form.append(qty,reason,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {data,error}=await db.rpc("amazon_dispose_defects",{p_quality_receipt_id:qr.id,p_quantity:Number(qty.value),p_reason:reason.value});if(error)throw error;say("Quarantine’dan "+qty.value+" dona chiqarildi. Qoldiq: "+data.remaining_quarantine,true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
    line.append(form);card.append(line);
   }
   host.append(card);
  }
  if(activeRole==="transport"){
   const card=el("div","competition-task-card");card.append(el("h4","","Transport Manager · Dispatch & delivery"),el("p","","Economy: $1.75/unit · 3 kun · 2,500 dona/round | Standard: $2.50/unit · 2 kun · 2,200 dona/round | Express: $4.25/unit · 1 kun · 1,000 dona/round."));
   const inbound=el("div","competition-task-card");inbound.append(el("b","","Inbound supply monitoring"));
   const inboundOpen=pos.filter(p=>["placed","partially_received"].includes(p.status));
   if(!inboundOpen.length)inbound.append(el("p","empty-state","Ochiq inbound PO yo‘q."));
   for(const po of inboundOpen)inbound.append(el("p","",po.po_number+" · "+po.sku+" · "+(po.quantity-po.received_quantity)+" dona kutilmoqda · ETA "+new Date(po.available_at||po.expected_at).toLocaleDateString()));
   card.append(inbound);
   const readyMap=new Map(fulfilment.map(x=>[x.order_id,Number(x.ready_quantity)]));
   for(const order of orders){
    const ready=readyMap.get(order.id)||0;if(ready<=0)continue;
    const line=el("div","competition-task-card");line.append(el("b","",order.order_number+" · "+order.item_name),el("p","",ready+" dona pick/pack qilingan, jo‘natishga tayyor."));
    const form=el("form","competition-inline-form"),q=el("input","");q.type="number";q.min="1";q.max=String(ready);q.value=String(ready);q.required=true;
    const carrier=el("input","");carrier.value="Regional carrier";carrier.placeholder="Carrier";
    const service=el("select","");service.append(option("Economy · $1.75/unit · 3 days","economy"),option("Standard · $2.50/unit · 2 days","standard"),option("Express · $4.25/unit · 1 day","express"));service.value="standard";
    const btn=el("button","secondary-button","Jo‘natmani dispatch qilish");btn.type="submit";form.append(q,carrier,service,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("amazon_dispatch_shipment_v2",{p_order_id:order.id,p_quantity:Number(q.value),p_carrier:carrier.value,p_service_level:service.value});if(error)throw error;say("Jo‘natma yo‘lga chiqdi. Tanlangan xizmatga qarab ETA belgilandi.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
    line.append(form);card.append(line);
   }
   if(!card.querySelector(".competition-task-card"))card.append(el("p","empty-state","Hozircha dispatch uchun tayyor pick/pack buyurtma yo‘q."));
   host.append(card);
  }
  if(shipments.length){
   const shipCard=el("div","competition-task-card");shipCard.append(el("h4","","Shipment tracking & delivery confirmation"));
   for(const shipment of shipments){
    const line=el("div","competition-task-card");line.append(el("b","",shipment.destination+" · "+shipment.quantity+" dona"),el("p","",shipment.carrier+" · "+statusLabel(shipment.status)+" · ETA "+new Date(shipment.eta).toLocaleDateString()));
    if(activeRole==="transport"&&["in_transit","delayed"].includes(shipment.status)&&new Date(shipment.eta)<=new Date(clock.virtual_now)&&activeCompetition.status==="active"){
     const btn=el("button","secondary-button","Yetkazib berilganini tasdiqlash");btn.type="button";
     btn.addEventListener("click",async()=>{btn.disabled=true;try{const {data,error}=await db.rpc("competition_deliver_shipment",{p_shipment_id:shipment.id});if(error)throw error;say(data.on_time?"Buyurtma vaqtida yetkazildi; tushum qayd etildi.":"Buyurtma kech yetkazildi; tushum qayd etildi.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
     line.append(btn);
    }
    shipCard.append(line);
   }
   host.append(shipCard);
  }
  if(approvals.length){
   const card=el("div","competition-task-card");card.append(el("h4","","Jamoa tasdiqlari"));
   for(const a of approvals){
    const row=el("div","competition-task-card");row.append(el("b","",statusLabel(a.approval_type)),el("p","",a.reason),el("small","", "Ha: "+a.approve_votes+" · Yo‘q: "+a.reject_votes));
    if(a.requested_by!==user.id){
     for(const [label,vote] of [["Tasdiqlash","approve"],["Rad etish","reject"]]){
      const btn=el("button","secondary-button",label);btn.type="button";btn.addEventListener("click",async()=>{btn.disabled=true;try{const {data,error}=await db.rpc("amazon_vote_approval",{p_approval_id:a.id,p_vote:vote});if(error)throw error;say("Ovoz qayd etildi: "+data.status,true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});row.append(btn);
     }
    }
    card.append(row);
   }
   host.append(card);
  }
  host.append(el("small","form-hint","Eslatma: bu Amazon’dan ilhomlangan, barcha raqam va supplier shartlari sun’iy bo‘lgan o‘quv simulyatsiyasi."));
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
   db.from("competition_teams").select("production_capacity_units,company_templates(operating_profile)").eq("id",teamId).single(),
   db.from("competition_production_runs").select("production_round,produced_quantity").eq("team_id",teamId).eq("status","completed")
  ]);
  for(const r of [metricResult,supplierResult,inventoryResult,poResult,orderResult,shipmentResult,clockResult,taskMetricResult,teamResult,productionResult])if(r.error)throw r.error;
  const canOperate=activeCompetition.status==="active";
  const canPlan=canOperate&&clockResult.data.current_round<clockResult.data.round_limit;
  for(const id of ["competitionSupplierTermsForm","competitionPurchaseOrderForm","competitionProductionForm","competitionCustomerOrderForm","competitionDecisionForm"]){const form=$(id);const enabled=id==="competitionDecisionForm"?canOperate:canPlan;if(form)form.querySelectorAll("input,select,textarea,button").forEach(control=>control.disabled=!enabled);}
  const producedThisRound=(productionResult.data||[]).filter(x=>x.production_round===clockResult.data.current_round).reduce((sum,x)=>sum+Number(x.produced_quantity),0);
  const remainingProductionCapacity=Math.max(0,Number(teamResult.data.production_capacity_units)-producedThisRound);
  $("competitionCustomerDue").min=localDateTimeValue(clockResult.data.virtual_now);
  const finalSimulationDate=new Date(new Date(clockResult.data.virtual_now).getTime()+Math.max(0,clockResult.data.round_limit-clockResult.data.current_round)*7*86400000);
  $("competitionCustomerDue").max=localDateTimeValue(finalSimulationDate);
  const marketPrice=Number(teamResult.data.company_templates?.operating_profile?.selling_price||0);
  if(marketPrice>0){$("competitionCustomerPrice").min=(marketPrice*.8).toFixed(2);$("competitionCustomerPrice").max=marketPrice.toFixed(2);$("competitionCustomerPrice").value=marketPrice.toFixed(2);}
  $("competitionProductionQuantity").max=String(Math.max(1,remainingProductionCapacity));
  $("competitionProductionQuantity").disabled=remainingProductionCapacity===0||!canPlan;
  $("competitionProductionCapacityNote").textContent="Round "+clockResult.data.current_round+": "+producedThisRound+" / "+teamResult.data.production_capacity_units+" units produced · "+remainingProductionCapacity+" remaining.";
  const productionSubmit=$("competitionProductionForm").querySelector("button");
  if(productionSubmit)productionSubmit.disabled=remainingProductionCapacity===0||!canPlan;
  const m=metricResult.data,suppliers=supplierResult.data||[],inventory=inventoryResult.data||[],pos=poResult.data||[],orders=orderResult.data||[],shipments=shipmentResult.data||[];
  const virtualNow=new Date(clockResult.data.virtual_now);
  const liveChallenges=[];
  const addChallenge=(severity,title,domain,prompt,evidence)=>liveChallenges.push({severity,title,domain,prompt,evidence,rank:severity==="CRITICAL"?3:severity==="HIGH"?2:1});
  const remainingForOrder=order=>Math.max(0,Number(order.quantity)-shipments.filter(s=>s.order_id===order.id&&s.status!=="cancelled").reduce((sum,s)=>sum+Number(s.quantity),0));
  if(activeRole==="warehouse"){
   for(const item of inventory.filter(x=>Number(x.quantity)<=Number(x.reorder_level)).slice(0,3)){
    addChallenge(Number(item.quantity)===0?"CRITICAL":"HIGH","Replenishment exception · "+item.item_name,"inventory",
     "Available stock is "+item.quantity+" units against a reorder point of "+item.reorder_level+". Calculate the replenishment gap, inventory position including open POs, and the service risk before deciding whether to expedite or wait.",
     "SKU "+item.sku+" · "+item.quantity+" on hand · reorder at "+item.reorder_level);
   }
   for(const po of pos.filter(x=>["placed","partially_received"].includes(x.status)).slice(0,2)){
    const available=new Date(po.available_at||po.expected_at),days=(available-virtualNow)/86400000;
    if(days<=3){
     addChallenge(days<=0?"HIGH":"MEDIUM","Inbound receipt control · "+po.po_number,"inventory",
      "Purchase order "+po.po_number+" has "+(po.quantity-po.received_quantity)+" units outstanding. Availability is "+(days<=0?"reached":"in "+Math.max(0,days).toFixed(1)+" virtual days")+". Decide the receiving sequence, verify quantity and protect put-away capacity.",
      po.item_name+" · "+po.received_quantity+"/"+po.quantity+" received");
    }
   }
   for(const item of inventory.filter(x=>Number(x.reorder_level)>0&&Number(x.quantity)>Number(x.reorder_level)*2.5).slice(0,1)){
    addChallenge("MEDIUM","Excess inventory exposure · "+item.item_name,"inventory",
     "Stock is above 2.5 times its reorder point. Quantify the cash tied up and holding-cost exposure, then recommend a controlled reduction without creating a stockout.",
     "SKU "+item.sku+" · "+item.quantity+" units · reorder point "+item.reorder_level);
   }
  }
  if(["procurement","supplier"].includes(activeRole)){
   for(const supplier of suppliers.filter(x=>x.active&&(Number(x.reliability_score)<92||Number(x.lead_time_days)>Number(x.base_lead_time_days)||Number(x.unit_cost)>Number(x.base_unit_cost))).slice(0,3)){
    addChallenge(Number(supplier.reliability_score)<85?"CRITICAL":"HIGH","Supplier performance variance · "+supplier.name,"procurement",
     "Current supplier terms differ from baseline. Compare price, lead time and reliability; quantify the service exposure and propose an SLA recovery or alternative-source plan without improving every term for free.",
     "Reliability "+supplier.reliability_score+"% · lead time "+supplier.lead_time_days+" days · unit cost "+Number(supplier.unit_cost).toFixed(2));
   }
  }
  if(activeRole==="manufacturer"){
   const raw=inventory.filter(x=>x.item_type==="raw_material").reduce((sum,x)=>sum+Number(x.quantity),0);
   const finished=inventory.filter(x=>x.item_type==="finished_goods").reduce((sum,x)=>sum+Number(x.quantity),0);
   const openDemand=orders.filter(x=>!["delivered","cancelled"].includes(x.status)).reduce((sum,x)=>sum+remainingForOrder(x),0);
   const productionNeed=Math.max(0,openDemand-finished);
   if(productionNeed>raw){
    addChallenge("CRITICAL","Raw-material constraint","production",
     "Open unshipped demand exceeds available raw material by "+(productionNeed-raw)+" units. Calculate feasible good output, protect safety stock and coordinate a recovery plan with Procurement and Warehouse.",
     "Open demand "+openDemand+" · finished stock "+finished+" · raw material "+raw);
   }
   if(productionNeed>remainingProductionCapacity){
    addChallenge("HIGH","Production capacity bottleneck","production",
     "Remaining round capacity is "+remainingProductionCapacity+" units against estimated net production need of "+productionNeed+". Build a feasible schedule and quantify the service impact of overtime, partial fulfilment or reprioritisation.",
     "Round "+clockResult.data.current_round+" · capacity remaining "+remainingProductionCapacity);
   }
  }
  if(activeRole==="transport"){
   for(const order of orders.filter(x=>!["delivered","cancelled"].includes(x.status)).map(order=>({...order,remaining:remainingForOrder(order),days:(new Date(order.due_at)-virtualNow)/86400000})).filter(x=>x.remaining>0&&x.days<=3).sort((a,b)=>a.days-b.days).slice(0,3)){
    addChallenge(order.days<0?"CRITICAL":"HIGH","Customer due-date exposure · "+order.order_number,"transport",
     "There are "+order.remaining+" units still to dispatch and the due date is "+(order.days<0?Math.abs(order.days).toFixed(1)+" virtual days overdue":"in "+order.days.toFixed(1)+" virtual days")+". Compare route speed, cost and load capacity; propose a dispatch sequence that minimises expected late units.",
     order.item_name+" · "+order.remaining+" units remaining");
   }
   for(const shipment of shipments.filter(x=>x.status==="delayed"||(x.status==="in_transit"&&new Date(x.eta)<virtualNow)).slice(0,2)){
    addChallenge("CRITICAL","Shipment exception · "+shipment.destination,"transport",
     "Shipment ETA has passed or the shipment is marked delayed. Assess customer impact, escalation timing and recovery routing; document who must be notified and what evidence confirms delivery.",
     shipment.quantity+" units · "+shipment.carrier+" · ETA "+new Date(shipment.eta).toLocaleDateString());
   }
  }
  if(activeRole==="finance"&&Number(m.cash_balance)<Number(m.starting_capital||100000)*.25){
   addChallenge("HIGH","Working-capital pressure","finance",
    "Cash balance has fallen below 25% of starting capital. Analyse outstanding purchase commitments, production costs and receivables; recommend which spend to defer without breaking customer service.",
    "Cash balance "+Number(m.cash_balance).toFixed(2));
  }
  if(!liveChallenges.length){
   const domain={warehouse:"inventory",procurement:"procurement",supplier:"procurement",manufacturer:"production",transport:"transport",finance:"finance",customer:"customer_service",retailer:"customer_service",operations:"strategy",analyst:"strategy"}[activeRole]||"strategy";
   addChallenge("MEDIUM","Preventive control review",domain,
    "No critical threshold exception is active in your team's current data. Identify the most likely supply-chain failure over the next round, quantify its probability or exposure, and recommend one preventive control with a measurable trigger.",
    "Round "+clockResult.data.current_round+" · current live team data");
  }
  liveChallenges.sort((a,b)=>b.rank-a.rank);
  renderLiveChallenges(liveChallenges);
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
   form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {data,error}=await db.rpc(isAmazonCase()?"amazon_receive_purchase_order":"competition_receive_purchase_order",{p_purchase_order_id:po.id,p_quantity:Number(qty.value)});if(error)throw error;say("Received "+data.received_quantity+" units; stock and cash updated.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
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
   if(activeRole==="transport"&&canPlan&&order.quantity>shipped){
    const form=el("form","competition-inline-form");
    const qty=el("input","");qty.type="number";qty.min="1";qty.max=String(order.quantity-shipped);qty.value=qty.max;qty.required=true;qty.setAttribute("aria-label","Quantity to dispatch");
    const origin=el("input","");origin.placeholder="Origin";origin.value="Company warehouse";origin.required=true;
    const dest=el("input","");dest.placeholder="Destination";dest.value="Customer distribution centre";dest.required=true;
    const carrier=el("input","");carrier.placeholder="Carrier";carrier.value="Regional carrier";carrier.required=true;
    const cost=el("input","");cost.type="number";cost.step=".01";cost.required=true;cost.setAttribute("aria-label","Transport cost");
    const transportRate=Number(teamResult.data.company_templates?.operating_profile?.transport_cost_per_unit||0);
    const updateTransportCostBounds=()=>{const quantity=Number(qty.value);cost.min=(quantity*transportRate*.8).toFixed(2);cost.max=(quantity*transportRate*1.5).toFixed(2);cost.value=(quantity*transportRate).toFixed(2);cost.title="Allowed "+cost.min+"–"+cost.max+". Economy ≤90% takes 3 days; standard takes 2; express ≥125% takes 1 day.";};
    updateTransportCostBounds();qty.addEventListener("input",updateTransportCostBounds);
    const costHint=el("small","","Economy ≤90%: 3 days · Standard: 2 days · Express ≥125%: 1 day");
    const btn=el("button","secondary-button","Dispatch");btn.type="submit";form.append(qty,origin,dest,carrier,cost,costHint,btn);
    form.addEventListener("submit",async e=>{e.preventDefault();btn.disabled=true;try{const {error}=await db.rpc("competition_dispatch_shipment",{p_order_id:order.id,p_quantity:Number(qty.value),p_origin:origin.value.trim(),p_destination:dest.value.trim(),p_carrier:carrier.value.trim(),p_transport_cost:Number(cost.value)});if(error)throw error;say("Shipment dispatched. Inventory and cash were updated.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});
    card.append(form);
   }
   $("competitionCustomerOrderList").append(card);
  }
  $("competitionShipmentList").replaceChildren();
  if(!shipments.length)addEmpty($("competitionShipmentList"),"No shipments have been dispatched.");
  if(canOperate&&!canPlan)$("competitionShipmentList").append(el("p","form-hint","Final round: new dispatches are closed. Confirm shipments that have reached their ETA."));
  for(const shipment of shipments){
   const card=el("article","competition-task-card");card.append(el("b","",shipment.destination+" · "+shipment.quantity+" units"),el("p","",shipment.carrier+" · "+statusLabel(shipment.status)+" · ETA "+new Date(shipment.eta).toLocaleString()));
   if(activeRole==="transport"&&["in_transit","delayed"].includes(shipment.status)&&activeCompetition.status==="active"){
    if(new Date(clockResult.data.virtual_now)>=new Date(shipment.eta)){
     const btn=el("button","secondary-button","Confirm delivery");btn.type="button";btn.addEventListener("click",async()=>{btn.disabled=true;try{const {data,error}=await db.rpc("competition_deliver_shipment",{p_shipment_id:shipment.id});if(error)throw error;say(data.on_time?"Delivered on time. Revenue recorded.":"Delivered late. Revenue recorded.",true);await loadTeamOperations();}catch(err){say(err.message);btn.disabled=false;}});card.append(btn);
    }else{card.append(el("small","", "Shipment in transit · Delivery can be confirmed after "+new Date(shipment.eta).toLocaleDateString()));}
   }
   $("competitionShipmentList").append(card);
  }
  setHidden("competitionSupplierPanel",isAmazonCase()||!["supplier","procurement"].includes(activeRole));
  setHidden("competitionSupplierTermsForm",isAmazonCase()||activeRole!=="supplier"||!canPlan);
  setHidden("competitionProcurementPanel",isAmazonCase()||activeRole!=="procurement");
  setHidden("competitionWarehousePanel",isAmazonCase()||activeRole!=="warehouse");
  setHidden("competitionManufacturerPanel",isAmazonCase()||activeRole!=="manufacturer");
  setHidden("competitionCustomerPanel",isAmazonCase()||!["customer","retailer","operations"].includes(activeRole));
  setHidden("competitionTransportPanel",isAmazonCase()||activeRole!=="transport");
  if(isAmazonCase())await renderAmazonCasePanel(teamId,clockResult.data);
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
   row.append(el("b","",(i+1)+". "+(p.full_name||"Student")+" · "+p.team_name),
    el("small","", "Decision avg "+(p.decision_average===null?"—":Number(p.decision_average).toFixed(1))+" · Case avg "+(p.task_average===null?"—":Number(p.task_average).toFixed(1))+" · 50/50"),
    el("small","",p.evaluated_decisions+" decisions + "+p.evaluated_tasks+" case tasks graded"),
    el("strong","",p.decision_average!==null&&p.task_average!==null?Number(p.average_score).toFixed(1)+"/100":"In progress"));
   $("competitionPublicIndividualRanking").append(row);
  }
  const finalWrap=$("competitionStudentFinalReportWrap");
  if(activeCompetition.status==="completed"){
   const {data:finalReports,error:finalReportError}=await db.rpc("get_competition_final_report",{p_competition_id:activeCompetition.id});
   if(finalReportError)throw finalReportError;
   setHidden("competitionStudentFinalReportWrap",false);
   renderFinalReport($("competitionStudentFinalReport"),(finalReports||[]).filter(item=>item.team_id===activeTeam));
  }else{
   setHidden("competitionStudentFinalReportWrap",true);
   $("competitionStudentFinalReport").replaceChildren();
  }
 }

 async function initialize(session){
  if(!session?.user){root.hidden=true;return;}
  user=session.user;
  try{
   const {data:profile,error}=await db.from("profiles").select("platform_role").eq("id",user.id).single();if(error)throw error;
   isTeacher=profile.platform_role==="teacher";root.hidden=false;
   $("competitionAccessNote").textContent=isTeacher?"Teacher control · configure teams, assign work and grade case submissions and decisions.":"Your company workspace · complete assigned work and record operational decisions.";
   setHidden("competitionTeacherPanel",!isTeacher);setHidden("competitionStudentPanel",isTeacher);
   if(isTeacher)await loadTemplates();
   await loadClassrooms();
  }catch(err){root.hidden=false;say("Competition engine could not load: "+err.message);}
 }

 $("competitionRefreshButton").addEventListener("click",async()=>{
  const btn=$("competitionRefreshButton");btn.disabled=true;
  try{if(activeCompetition)await loadCompetition();else await loadCompetitions();say("Competition data refreshed.",true);}
  catch(err){say(err.message);}
  finally{btn.disabled=false;}
 });
 $("competitionClassSelect").addEventListener("change",async()=>{activeClassId=$("competitionClassSelect").value;try{await loadCompetitions();say("");}catch(err){say(err.message);}});
 $("competitionSelect").addEventListener("change",async()=>{activeCompetition={id:$("competitionSelect").value};try{await loadCompetition();say("");}catch(err){say(err.message);}});
 $("competitionCreateForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionCreateButton");btn.disabled=true;
  try{const {data,error}=await db.rpc("create_competition",{p_classroom_id:activeClassId,p_title:$("competitionTitle").value.trim(),p_settings:{case_code:"amazon-global-combined-crisis",round_count:3,round_duration_minutes:10,horizon_days:30,demand_shock_pct:40,main_supplier_delay_days:10,scoring_version:"amazon-global-v1"}});if(error)throw error;
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
  try{const {data:teamId,error}=await db.rpc("create_competition_team",{p_competition_id:activeCompetition.id,p_team_name:$("competitionManualTeamName").value.trim(),p_company_template_id:$("competitionTemplateSelect").value});if(error)throw error;
   if(isAmazonCase()){const init=await db.rpc("amazon_initialize_team",{p_team_id:teamId});if(init.error)throw init.error;}
   $("competitionManualTeamName").value="";say("Team created. Assign its students below.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionTaskPackButton").addEventListener("click",async()=>{
  const btn=$("competitionTaskPackButton");btn.disabled=true;
  try{const {data,error}=await db.rpc(isAmazonCase()?"amazon_create_role_tasks":"create_competition_standard_task_pack",{p_competition_id:activeCompetition.id});if(error)throw error;say(data+" individual role case tasks created across all teams.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
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
  try{let error=null;if(isAmazonCase()){const supplier=await db.from("competition_suppliers").select("supplier_code").eq("id",$("competitionPOSupplier").value).single();if(supplier.error)throw supplier.error;const result=await db.rpc("amazon_place_purchase_order",{p_team_id:activeTeam,p_supplier_code:supplier.data.supplier_code,p_sku:$("competitionPOSku").value.trim(),p_quantity:Number($("competitionPOQuantity").value),p_order_day:null});error=result.error;}else{const result=await db.rpc("competition_create_purchase_order",{p_team_id:activeTeam,p_supplier_id:$("competitionPOSupplier").value,p_sku:$("competitionPOSku").value.trim(),p_item_name:$("competitionPOItemName").value.trim(),p_quantity:Number($("competitionPOQuantity").value)});error=result.error;}if(error)throw error;say("Purchase order placed. Supplier capacity, MOQ, budget and ETA validated.",true);await loadTeamOperations();}catch(err){say(err.message);}finally{btn.disabled=false;}
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
  try{const {data,error}=await db.rpc(isAmazonCase()?"amazon_advance_round":"competition_advance_round",{p_competition_id:activeCompetition.id});if(error)throw error;say("Advanced to round "+data.current_round+". Simulation time moved forward "+(data.days_advanced||7)+" days.",true);await loadCompetition();}catch(err){say(err.message);btn.disabled=false;}
 });
 $("competitionCalculateScores").addEventListener("click",async()=>{
  const btn=$("competitionCalculateScores");btn.disabled=true;
  try{const {data:clock,error:clockError}=await db.from("competition_simulation_clock").select("current_round").eq("competition_id",activeCompetition.id).single();if(clockError)throw clockError;const {data,error}=await db.rpc("calculate_competition_scores",{p_competition_id:activeCompetition.id,p_round_number:clock.current_round});if(error)throw error;say(data+" team score snapshots calculated for round "+clock.current_round+".",true);await loadCompetition();}catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 $("competitionDecisionForm").addEventListener("submit",async e=>{
  e.preventDefault();const btn=$("competitionDecisionButton");btn.disabled=true;
  try{const {error}=await db.rpc("record_competition_decision",{p_competition_id:activeCompetition.id,p_team_id:activeTeam,p_domain:$("competitionDecisionDomain").value,p_decision_type:$("competitionDecisionType").value.trim(),p_selected_option:$("competitionDecisionOption").value.trim(),p_rationale:$("competitionDecisionRationale").value.trim(),p_inputs:{role:activeRole,calculations:$("competitionDecisionCalculations").value.trim(),risk_mitigation:$("competitionDecisionRisk").value.trim(),expected_impact:$("competitionDecisionImpact").value.trim()}});if(error)throw error;
   $("competitionDecisionForm").reset();say("Your decision was recorded.",true);await loadCompetition();
  }catch(err){say(err.message);}finally{btn.disabled=false;}
 });
 window.addEventListener("classroom-updated",async()=>{try{await loadClassrooms();say("Classroom list refreshed.",true);}catch(err){say(err.message);}});
 db.auth.getSession().then(({data})=>initialize(data.session));
 db.auth.onAuthStateChange((_event,session)=>{if(session)setTimeout(()=>initialize(session),0);else{root.hidden=true;user=null;activeCompetition=null;}});
}
