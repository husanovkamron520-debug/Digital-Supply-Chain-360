import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#classroomWorkspace");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const createForm = document.querySelector("#createClassForm");
  const joinForm = document.querySelector("#joinClassForm");
  const list = document.querySelector("#classroomList");
  const message = document.querySelector("#classroomMessage");
  const roleLabel = document.querySelector("#classroomRoleLabel");
  const intro = document.querySelector("#classroomIntro");
  const title = document.querySelector("#classroomHeading");
  const listTitle = document.querySelector("#classListTitle");
  let currentUser = null;
  let currentRole = "student";

  function say(text, success=false) {
    message.textContent = text;
    message.classList.toggle("success", success);
  }
  function makeCode() {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, b => chars[b % chars.length]).join("");
  }
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  async function loadTeacherClasses() {
    const {data, error} = await db.from("classrooms").select("id,name,join_code,created_at").eq("teacher_id", currentUser.id).order("created_at",{ascending:false});
    if (error) throw error;
    list.replaceChildren();
    if (!data.length) { list.append(el("p","empty-state","You have not created a classroom yet.")); return; }
    for (const classroom of data) {
      const card=el("article","classroom-card");
      const head=el("div","classroom-card-head");
      const name=el("div");
      name.append(el("b","",classroom.name),el("small","","Share this code with your students"));
      head.append(name,el("span","join-code",classroom.join_code));
      card.append(head);
      const actions=el("div","classroom-card-actions");
      const copy=el("button","copy-code","Copy class code");
      copy.type="button";
      copy.addEventListener("click",async()=>{try{await navigator.clipboard.writeText(classroom.join_code);say("Class code copied.",true);}catch{say("Copy is unavailable; share the displayed code manually.");}});
      const membersButton=el("button","member-toggle","View students");
      membersButton.type="button";
      const members=el("div","member-list");
      members.hidden=true;
      membersButton.addEventListener("click",async()=>{
        members.hidden=!members.hidden;
        if(!members.hidden && !members.dataset.loaded){
          members.replaceChildren(el("p","empty-state","Loading students…"));
          try{
            const {data:rows,error:memberError}=await db.from("classroom_members").select("id,operational_role,profiles(full_name)").eq("classroom_id",classroom.id).order("joined_at");
            if(memberError)throw memberError;
            members.replaceChildren();
            if(!rows.length)members.append(el("p","empty-state","No students have joined yet."));
            for(const row of rows){
              const line=el("div","member-row");
              line.append(el("span","",row.profiles?.full_name||"Student"));
              const select=el("select");
              for(const [value,label] of [["supplier","Supplier"],["manufacturer","Manufacturer"],["warehouse","Warehouse"],["transport","Transport"],["retailer","Retailer"],["customer","Customer"]]){
                const option=el("option","",label);option.value=value;option.selected=row.operational_role===value;select.append(option);
              }
              select.addEventListener("change",async()=>{
                select.disabled=true;
                const {error:updateError}=await db.from("classroom_members").update({operational_role:select.value}).eq("id",row.id);
                select.disabled=false;
                if(updateError)say(updateError.message);else say("Student role updated.",true);
              });
              line.append(select);members.append(line);
            }
            members.dataset.loaded="true";
          }catch(err){members.replaceChildren(el("p","empty-state",err.message));}
        }
      });
      actions.append(copy,membersButton);card.append(actions,members);list.append(card);
    }
  }
  async function loadStudentClasses() {
    const {data,error}=await db.from("classroom_members").select("id,operational_role,classrooms(id,name,teacher_id)").eq("student_id",currentUser.id).order("joined_at",{ascending:false});
    if(error)throw error;
    list.replaceChildren();
    if(!data.length){list.append(el("p","empty-state","You have not joined a classroom yet. Ask your teacher for a class code."));return;}
    for(const row of data){
      const card=el("article","classroom-card");
      card.append(el("b","",row.classrooms?.name||"Classroom"));
      card.append(el("small","","Your operational role: "+row.operational_role));
      list.append(card);
    }
  }
  async function refresh() {
    if(!currentUser)return;
    try {
      if(currentRole==="teacher") await loadTeacherClasses();
      else await loadStudentClasses();
    } catch(error) {
      list.replaceChildren(el("p","empty-state",error.message));
      say("Could not load classrooms. Check that the database schema is installed.");
    }
  }
  async function initialize(session) {
    if(!session?.user){root.hidden=true;return;}
    currentUser=session.user;
    const {data:profile,error}=await db.from("profiles").select("full_name,platform_role").eq("id",currentUser.id).single();
    if(error){say("Profile could not be loaded: "+error.message);return;}
    currentRole=profile.platform_role||"student";
    root.hidden=false;
    roleLabel.textContent=currentRole.toUpperCase();
    if(currentRole==="teacher"){
      title.textContent="Teacher workspace";
      intro.textContent="Create a classroom, share its join code, and assign operational roles to students.";
      createForm.hidden=false;joinForm.hidden=true;listTitle.textContent="Classrooms you manage";
    }else{
      title.textContent="Student workspace";
      intro.textContent="Join your teacher’s classroom with a code. Your teacher can assign your supply-chain role.";
      createForm.hidden=true;joinForm.hidden=false;listTitle.textContent="Your classrooms";
    }
    await refresh();
  }
  createForm.addEventListener("submit",async event=>{
    event.preventDefault();
    if(currentRole!=="teacher")return;
    const button=createForm.querySelector("button");
    button.disabled=true;say("");
    try{
      const name=document.querySelector("#classroomName").value.trim();
      const {data,error}=await db.rpc("create_classroom",{p_name:name,p_join_code:makeCode()});
      if(error)throw error;
      createForm.reset();say("Classroom created. Share its join code with students.",true);await refresh();
    }catch(error){say(error.message);}
    finally{button.disabled=false;}
  });
  joinForm.addEventListener("submit",async event=>{
    event.preventDefault();
    if(currentRole!=="student")return;
    const button=joinForm.querySelector("button");
    button.disabled=true;say("");
    try{
      const code=document.querySelector("#joinCode").value.trim().toUpperCase();
      const {error}=await db.rpc("join_classroom",{p_join_code:code});
      if(error)throw error;
      joinForm.reset();say("You joined the classroom successfully.",true);await refresh();
    }catch(error){say(error.message);}
    finally{button.disabled=false;}
  });
  db.auth.getSession().then(({data})=>initialize(data.session));
  db.auth.onAuthStateChange((_event,session)=>{if(session)setTimeout(()=>initialize(session),0);else{root.hidden=true;currentUser=null;}});
}
