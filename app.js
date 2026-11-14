import * as THREE from "three";

const stageData = [
  {name:"Supplier",sub:"Raw materials",detail:"Supplier portal · purchase orders · inbound quality",system:"ERP / SRM"},
  {name:"Factory",sub:"Production",detail:"Production planning · manufacturing execution · quality control",system:"ERP / MES"},
  {name:"Warehouse",sub:"Storage",detail:"Inventory visibility · receiving · picking and packing",system:"WMS"},
  {name:"Transport",sub:"In transit",detail:"Fleet allocation · route optimisation · shipment tracking",system:"TMS / IoT"},
  {name:"Customer",sub:"Delivery",detail:"Order fulfilment · proof of delivery · customer feedback",system:"CRM"}
];

const sceneHost = document.querySelector("#scene");
const tooltip = document.querySelector("#sceneTooltip");
let scene, camera, renderer, root, raycaster, pointer;
let nodeMeshes = [], movingPackages = [], digitalLines = [];
let selectedStage = 0, digitalMode = false, disrupted = false, animationFrame;
const clock = new THREE.Clock();

function material(color, emissive = color) {
  return new THREE.MeshStandardMaterial({color, roughness:.55, metalness:.22, emissive, emissiveIntensity:.16});
}
function line(points, color, opacity=.65, dashed=false) {
  const geometry = new THREE.BufferGeometry().setFromPoints(points);
  const mat = dashed
    ? new THREE.LineDashedMaterial({color,transparent:true,opacity,dashSize:.13,gapSize:.09})
    : new THREE.LineBasicMaterial({color,transparent:true,opacity});
  const obj = new THREE.Line(geometry,mat);
  if(dashed) obj.computeLineDistances();
  root.add(obj);
  return obj;
}
function addNode(index, x, y, z, color, shape) {
  const group = new THREE.Group();
  group.position.set(x,y,z);
  const core = shape === "box"
    ? new THREE.Mesh(new THREE.BoxGeometry(.72,.62,.62),material(color))
    : new THREE.Mesh(new THREE.IcosahedronGeometry(.43,1),material(color));
  core.userData.stage = index;
  core.userData.isStageNode = true;
  group.add(core);
  const ring = new THREE.Mesh(new THREE.TorusGeometry(.57,.012,5,48),new THREE.MeshBasicMaterial({color,transparent:true,opacity:.7}));
  ring.rotation.x = Math.PI/2;
  group.add(ring);
  const halo = new THREE.Mesh(new THREE.SphereGeometry(.67,20,20),new THREE.MeshBasicMaterial({color,transparent:true,opacity:.045,depthWrite:false}));
  group.add(halo);
  root.add(group);
  nodeMeshes.push({group,core,ring,index});
  return group;
}
function addBuilding(x,z,color,scale=1) {
  const g = new THREE.Group();
  g.position.set(x,0,z);
  const base = new THREE.Mesh(new THREE.BoxGeometry(1.35*scale,.45*scale,1.05*scale),material("#20384d","#102638"));
  base.position.y=.22*scale;g.add(base);
  const top = new THREE.Mesh(new THREE.BoxGeometry(1.12*scale,.58*scale,.85*scale),material(color));
  top.position.y=.7*scale;g.add(top);
  for(let i=0;i<3;i++){
    const win = new THREE.Mesh(new THREE.BoxGeometry(.12*scale,.18*scale,.025),new THREE.MeshBasicMaterial({color:"#8bdedb"}));
    win.position.set(-.34*scale+i*.32*scale,.72*scale,.44*scale);g.add(win);
  }
  root.add(g);
}
function addPackage(x,y,z,color="#f4bd68") {
  const m = new THREE.Mesh(new THREE.BoxGeometry(.13,.13,.13),new THREE.MeshStandardMaterial({color,emissive:color,emissiveIntensity:.4}));
  m.position.set(x,y,z);root.add(m);
  movingPackages.push(m);
}
function setupScene() {
  if(!sceneHost || !window.WebGLRenderingContext) { sceneHost.textContent="3D preview is unavailable in this browser."; return; }
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(38,1,.1,100);
  camera.position.set(0,5.5,10.8);
  camera.lookAt(0,.3,0);
  try { renderer = new THREE.WebGLRenderer({antialias:true,alpha:true}); }
  catch { sceneHost.textContent="WebGL is unavailable on this device."; return; }
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.7));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  sceneHost.appendChild(renderer.domElement);
  scene.add(new THREE.AmbientLight("#9bbbd2",1.3));
  const key = new THREE.DirectionalLight("#b9e9f0",2.2);key.position.set(-4,8,6);scene.add(key);
  root = new THREE.Group();scene.add(root);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(15,8),new THREE.MeshBasicMaterial({color:"#102236",transparent:true,opacity:.34}));
  floor.rotation.x=-Math.PI/2;floor.position.y=-.08;root.add(floor);
  const grid = new THREE.GridHelper(15,30,"#29465c","#1a3044");grid.position.y=-.065;root.add(grid);

  const positions=[[-5,0,0],[-2.5,.15,0],[0,0,0],[2.5,.15,0],[5,0,0]];
  const colors=["#58d6a3","#6d9cff","#53d5d0","#f1b95f","#b49aff"];
  positions.forEach((p,i)=>addNode(i,p[0],p[1],p[2],colors[i],i===1||i===2?"box":"icosa"));
  addBuilding(-2.5,-.9,"#385c75",.9);
  addBuilding(0,-.95,"#2e6970",1.05);
  addBuilding(2.5,-.9,"#735b37",.8);
  for(let i=0;i<4;i++) line([new THREE.Vector3(positions[i][0]+.48,.05,0),new THREE.Vector3(positions[i+1][0]-.48,.05,0)],"#e9b96d",.9);
  for(let i=0;i<4;i++) line([new THREE.Vector3(positions[i][0],.42,.12),new THREE.Vector3(positions[i+1][0],.42,.12)],"#6b9fff",.5,true);
  for(let i=0;i<22;i++) addPackage(-5+(i%11)*.91,.18+(i%3)*.04,(i%2)*.18-.09);
  raycaster=new THREE.Raycaster();pointer=new THREE.Vector2();
  renderer.domElement.addEventListener("pointerdown",onPointerDown);
  let dragging=false,previousX=0,previousY=0;
  renderer.domElement.addEventListener("pointerdown",e=>{dragging=true;previousX=e.clientX;previousY=e.clientY;});
  window.addEventListener("pointerup",()=>dragging=false);
  renderer.domElement.addEventListener("pointermove",e=>{
    if(dragging && e.buttons){root.rotation.y+=(e.clientX-previousX)*.006;root.rotation.x=Math.max(-.3,Math.min(.3,root.rotation.x+(e.clientY-previousY)*.003));previousX=e.clientX;previousY=e.clientY;}
  });
  renderer.domElement.addEventListener("wheel",e=>{camera.position.z=Math.max(7,Math.min(15,camera.position.z+e.deltaY*.008));},{passive:true});
  resizeScene();
  window.addEventListener("resize",resizeScene);
  animate();
}
function onPointerDown(event){
  if(!renderer||!root)return;
  const rect=renderer.domElement.getBoundingClientRect();
  pointer.x=((event.clientX-rect.left)/rect.width)*2-1;
  pointer.y=-((event.clientY-rect.top)/rect.height)*2+1;
  raycaster.setFromCamera(pointer,camera);
  const hits=raycaster.intersectObjects(nodeMeshes.map(n=>n.core),false);
  if(hits.length) selectStage(hits[0].object.userData.stage);
}
function resizeScene(){
  if(!renderer||!camera)return;
  const w=sceneHost.clientWidth,h=sceneHost.clientHeight;
  camera.aspect=w/h;camera.updateProjectionMatrix();renderer.setSize(w,h,false);
}
function animate(){
  animationFrame=requestAnimationFrame(animate);
  const t=clock.getElapsedTime();
  nodeMeshes.forEach(n=>{
    n.group.position.y=(n.index%2)*.12+Math.sin(t*1.2+n.index)*.045;
    n.ring.rotation.z=t*.22;
    const active=n.index===selectedStage;
    n.ring.scale.setScalar(active?1.16:1);
    n.core.material.emissiveIntensity=active?.65:.16;
  });
  movingPackages.forEach((p,i)=>{
    const speed=disrupted?.055:.12;
    const progress=(t*speed+i/22)%1;
    p.position.x=-5+progress*10;
    p.position.y=.18+Math.sin(progress*Math.PI)*.34;
    p.material.color.set(disrupted&&progress>.45?"#f08a62":"#f4bd68");
  });
  if(renderer)renderer.render(scene,camera);
}
function selectStage(index){
  selectedStage=index;
  document.querySelectorAll(".stage").forEach((el,i)=>el.classList.toggle("active",i===index));
  const item=stageData[index];
  tooltip.textContent=item.name+"  ·  "+item.detail;
}
function setDigitalMode(enabled){
  digitalMode=enabled;
  document.querySelectorAll(".view-chip").forEach(b=>b.classList.toggle("active",b.dataset.view===(enabled?"systems":"flow")));
  if(root){
    root.children.forEach(obj=>{
      if(obj.isLine && obj.material && obj.material.type==="LineDashedMaterial")obj.visible=enabled;
    });
    nodeMeshes.forEach(n=>n.ring.material.color.set(enabled?"#7f9dff":["#58d6a3","#6d9cff","#53d5d0","#f1b95f","#b49aff"][n.index]));
  }
  tooltip.textContent=enabled?"Digital layer · ERP / WMS / TMS / IoT / AI signals":"Physical layer · materials, production, inventory and delivery";
}
function addEvent(title,description,status="ALERT"){
  const list=document.querySelector("#eventList");
  const el=document.createElement("div");el.className="event";
  el.innerHTML='<span class="event-icon amber">!</span><div><b></b><p></p><small>Just now</small></div><span class="event-status info"></span>';
  el.querySelector("b").textContent=title;el.querySelector("p").textContent=description;el.querySelector(".event-status").textContent=status;
  list.prepend(el);
  document.querySelector("#eventCount").textContent=String(list.children.length).padStart(2,"0")+" EVENTS";
}
function runScenario(){
  disrupted=!disrupted;
  const btn=document.querySelector("#scenarioBtn");
  if(disrupted){
    document.querySelector("#otd").innerHTML='87.6<span>%</span>';
    document.querySelector("#inventory").textContent="1,080";
    document.querySelector("#leadtime").innerHTML='8.1<span class="unit"> days</span>';
    document.querySelector("#insightText").textContent="Supplier delay detected. Inbound materials are arriving late, putting production continuity and delivery performance at risk.";
    btn.innerHTML="<span>↺</span> Restore normal operations";
    addEvent("Supplier delay detected","SUP-014 · Inbound materials delayed by 36 hours","RISK");
    selectStage(0);
  }else{
    document.querySelector("#otd").innerHTML='94.2<span>%</span>';
    document.querySelector("#inventory").textContent="1,240";
    document.querySelector("#leadtime").innerHTML='6.4<span class="unit"> days</span>';
    document.querySelector("#insightText").textContent="Your network is balanced. All major flows are operating within expected parameters.";
    btn.innerHTML="<span>＋</span> Run disruption scenario";
    addEvent("Network recovered","Contingency plan applied · Service levels restored","OK");
  }
}
document.querySelectorAll(".stage").forEach(el=>el.addEventListener("click",()=>selectStage(Number(el.dataset.stage))));
document.querySelectorAll(".view-chip").forEach(el=>el.addEventListener("click",()=>setDigitalMode(el.dataset.view==="systems")));
document.querySelector("#scenarioBtn").addEventListener("click",runScenario);
document.querySelector("#resetBtn").addEventListener("click",()=>{if(disrupted)runScenario();selectStage(0);setDigitalMode(false);});
document.querySelector("#focusBtn").addEventListener("click",()=>document.body.classList.toggle("focus-mode"));
document.querySelector("#clearEvents").addEventListener("click",()=>{document.querySelector("#eventList").innerHTML="";document.querySelector("#eventCount").textContent="00 EVENTS";});

function syncNavigation(){
  const activeHash=window.location.hash||"#overview";
  document.querySelectorAll(".nav-link").forEach(link=>{
    link.classList.toggle("active",link.getAttribute("href")===activeHash);
  });
}
document.querySelectorAll(".nav-link").forEach(link=>link.addEventListener("click",syncNavigation));
window.addEventListener("hashchange",syncNavigation);
syncNavigation();

setupScene();
selectStage(0);


// Dashboard scope switch: show only the signed-in user's workspace or the complete overview.
const myWorkspaceBtn=document.querySelector("#myWorkspaceBtn");
const overallOverviewBtn=document.querySelector("#overallOverviewBtn");
const scopeStatus=document.querySelector("#scopeStatus");
const mainContent=document.querySelector(".main-content");
function setDashboardView(view){
  const personal=view==="personal";
  const targetSelector=personal?(document.body.dataset.myWorkspaceTarget||"#scenarioWorkspace"):null;
  const target=personal?document.querySelector(targetSelector):null;
  if(personal&&(!target||target.hidden)){
    if(scopeStatus)scopeStatus.textContent=target
      ?"Your role workspace is still loading. Try again in a moment."
      :"Your role workspace is not available yet. Please wait for your classroom role to load.";
    return;
  }
  [...(mainContent?.children||[])].forEach(section=>{
    const keep=section.classList.contains("topbar")||section.classList.contains("dashboard-scope-bar")||section.id==="classroomWorkspace"||(personal&&section===target);
    if(keep)section.removeAttribute("data-scope-hidden");
    else if(personal)section.dataset.scopeHidden="true";
    else section.removeAttribute("data-scope-hidden");
  });
  myWorkspaceBtn?.classList.toggle("active",personal);
  overallOverviewBtn?.classList.toggle("active",!personal);
  myWorkspaceBtn?.setAttribute("aria-pressed",String(personal));
  overallOverviewBtn?.setAttribute("aria-pressed",String(!personal));
  if(scopeStatus)scopeStatus.textContent=personal
    ?"Showing the workspace assigned to your classroom role."
    :"Showing the complete supply-chain control tower and all available workspaces.";
  const crumb=document.querySelector(".crumb b");
  if(crumb)crumb.textContent=personal?"My workspace":"Global overview";
  const destination=personal?target:document.querySelector("#overview");
  destination?.scrollIntoView({behavior:"smooth",block:"start"});
}
myWorkspaceBtn?.addEventListener("click",()=>setDashboardView("personal"));
overallOverviewBtn?.addEventListener("click",()=>setDashboardView("overall"));
