// Lightweight application shell: navigation and personal workspace switching.
// The sample 3D control-tower demo has been removed from the home page.

function syncNavigation(){
  const activeHash=window.location.hash||"#overview";
  document.querySelectorAll(".nav-link").forEach(link=>{
    link.classList.toggle("active",link.getAttribute("href")===activeHash);
  });
}
document.querySelectorAll(".nav-link").forEach(link=>link.addEventListener("click",syncNavigation));
window.addEventListener("hashchange",syncNavigation);
syncNavigation();

const myWorkspaceBtn=document.querySelector("#myWorkspaceBtn");
const overallOverviewBtn=document.querySelector("#overallOverviewBtn");
const scopeStatus=document.querySelector("#scopeStatus");
const mainContent=document.querySelector(".main-content");

function setDashboardView(view){
  const personal=view==="personal";
  let targets=[];
  if(personal){
    try{
      targets=JSON.parse(document.body.dataset.myWorkspaceTargets||"[]");
    }catch{
      targets=[];
    }
    if(!targets.length&&document.body.dataset.myWorkspaceTarget){
      targets=[document.body.dataset.myWorkspaceTarget];
    }
    targets=[...new Set(targets)].map(selector=>document.querySelector(selector)).filter(Boolean);
    const available=targets.filter(section=>!section.hidden);
    if(!available.length){
      if(scopeStatus)scopeStatus.textContent=targets.length
        ?"Your role workspaces are still loading. Try again in a moment."
        :"Your role workspace is not available yet. Please wait for your classroom role to load.";
      return;
    }
    targets=available;
  }

  [...(mainContent?.children||[])].forEach(section=>{
    const keep=section.classList.contains("topbar")||
      section.classList.contains("dashboard-scope-bar")||
      section.id==="classroomWorkspace"||
      (personal&&targets.includes(section));
    if(keep)section.removeAttribute("data-scope-hidden");
    else if(personal)section.dataset.scopeHidden="true";
    else section.removeAttribute("data-scope-hidden");
  });

  myWorkspaceBtn?.classList.toggle("active",personal);
  overallOverviewBtn?.classList.toggle("active",!personal);
  myWorkspaceBtn?.setAttribute("aria-pressed",String(personal));
  overallOverviewBtn?.setAttribute("aria-pressed",String(!personal));
  if(scopeStatus)scopeStatus.textContent=personal
    ?"Showing all workspaces assigned to your classroom roles."
    :"Showing your classroom and available workspaces.";
  const crumb=document.querySelector(".crumb b");
  if(crumb)crumb.textContent=personal?"My workspace":"Classroom workspace";
  const destination=personal?targets[0]:document.querySelector("#overview");
  destination?.scrollIntoView({behavior:"smooth",block:"start"});
}

myWorkspaceBtn?.addEventListener("click",()=>setDashboardView("personal"));
overallOverviewBtn?.addEventListener("click",()=>setDashboardView("overall"));
