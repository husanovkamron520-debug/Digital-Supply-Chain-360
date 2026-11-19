import * as THREE from "three";
import { OrbitControls } from "https://cdn.jsdelivr.net/npm/three@0.169.0/examples/jsm/controls/OrbitControls.js";

const $ = (id) => document.getElementById(id);
const entryButton = $("warehouse3dOpenButton");
const workspace = $("warehouse3dWorkspace");
const sceneHost = $("warehouse3dScene");
let renderer=null,scene=null,camera=null,controls=null,animationFrame=0,resizeObserver=null;
let stockMeshes=[],currentInventory=[],selectedMesh=null,forklift=null,truck=null,scanBeam=null,conveyorPackages=[];
let motion=null,completedSteps=new Set(),busy=false;
const defaultInventory=[
 {sku:"SKU-01",item_name:"Wireless Earbuds",quantity:500,reorder_level:180,unit_cost:12},
 {sku:"SKU-02",item_name:"Wireless Mouse",quantity:700,reorder_level:220,unit_cost:8},
 {sku:"SKU-03",item_name:"Smart Watch",quantity:300,reorder_level:120,unit_cost:28},
 {sku:"SKU-04",item_name:"Coffee Maker",quantity:200,reorder_level:80,unit_cost:35},
 {sku:"SKU-05",item_name:"Ergonomic Office Chair",quantity:150,reorder_level:60,unit_cost:48}
];
const steps=[
 {id:"receiving",name:"Receiving",uz:"Yukni qabul qilish",desc:"Yuk mashinasi dockga keladi, palletlar tushirish maydoniga olinadi.",zone:"Qabul qilish zonasi",event:"Inbound yuk dockga yetib keldi."},
 {id:"qc",name:"Quality Control",uz:"Sifat nazorati",desc:"Qabul qilingan mahsulotlar skanerlanadi va sifat tekshiruvidan o‘tkaziladi.",zone:"QC nazorat zonasi",event:"SKU va sifat tekshiruvi bajarildi."},
 {id:"putaway",name:"Put-away",uz:"Javonga joylashtirish",desc:"Forklift palletlarni belgilangan SKU javonlariga olib boradi.",zone:"Saqlash javonlari",event:"Mahsulotlar ombor lokatsiyalariga joylashtirildi."},
 {id:"picking",name:"Picking",uz:"Buyurtma uchun terish",desc:"Buyurtma satrlari bo‘yicha mahsulotlar javondan yig‘ish zonasiga olib kelinadi.",zone:"Picking zonasi",event:"Buyurtma uchun mahsulotlar terildi."},
 {id:"packing",name:"Packing",uz:"Qadoqlash",desc:"Mahsulotlar konveyerda qadoqlash stansiyasidan o‘tadi.",zone:"Packing stansiyasi",event:"Buyurtmalar qadoqlandi va jo‘natishga tayyorlandi."},
 {id:"shipping",name:"Shipping",uz:"Jo‘natish",desc:"Tayyor palletlar transportga yuklanadi va ombordan jo‘natiladi.",zone:"Dispatch dock",event:"Yuk transportga topshirildi."}
];
const palette={healthy:0x21b98a,warning:0xe6a93d,critical:0xe45c68};
const statusFor=item=>{const q=Number(item.quantity)||0,r=Number(item.reorder_level)||0;return q<=r?"critical":q<=r*1.5?"warning":"healthy";};
const mat=(color,roughness=.75,metalness=.1)=>new THREE.MeshStandardMaterial({color,roughness,metalness});
function box(parent,pos,size,material,cast=true){const m=new THREE.Mesh(new THREE.BoxGeometry(...size),material);m.position.set(...pos);m.castShadow=cast;m.receiveShadow=true;parent.add(m);return m;}
function zone(x,z,w,d,color){const pad=box(scene,[x,.015,z],[w,.04,d],mat(color,.9),false);pad.material.transparent=true;pad.material.opacity=.3;const edge=box(scene,[x,.045,z-d/2],[w,.035,.08],mat(color),false);return pad;}
function addRack(x,index,item){
 const rack=new THREE.Group();rack.position.set(x,0,-1.2);scene.add(rack);
 const steel=mat(0x627c91,.4,.45),beam=mat(0xa2b5c4,.45,.35),deck=mat(0x2b455b,.65);
 for(const z of [-4,4])for(const dx of [-1.35,1.35])box(rack,[dx,2.5,z],[.15,5,.15],steel);
 for(let level=0;level<4;level++){
  const y=.72+level*1.25;box(rack,[0,y,0],[2.8,.12,8],deck);
  for(const z of [-4,4])box(rack,[0,y+.16,z],[2.9,.2,.16],beam);
  for(let bay=0;bay<3;bay++){
   const z=-2.7+bay*2.7,q=Math.max(0,Number(item.quantity)||0),fill=Math.min(1,(q/12)/Math.max(1,(Number(item.reorder_level)||1)/12*1.8));
   const h=.35+fill*.55,b=box(rack,[0,y+.22+h/2,z],[1.45,h,1.15],mat(palette[statusFor(item)],.5));
   b.userData={stock:item,rack:index,bay:bay+1,level:level+1};stockMeshes.push(b);
   const stripe=box(rack,[0,y+.22+h/2,z+.58],[1.48,.045,.035],mat(0xeaf4fb,.5),false);
   stripe.userData=b.userData;stockMeshes.push(stripe);
  }
 }
 for(const z of [-3.7,3.7]){const brace=box(rack,[0,2.5,z],[.07,4.7,.07],mat(0x91a8ba,.5));brace.rotation.z=.3;}
}
function makeForklift(){
 const g=new THREE.Group();scene.add(g);
 box(g,[0,.65,0],[1.5,.85,2],mat(0xe6a63b));
 box(g,[0,1.4,-.32],[1.12,.85,.12],mat(0x233b4f));
 box(g,[0,1.9,.15],[.95,.08,.08],mat(0x263d50));
 for(const x of [-.58,.58])for(const z of [-.62,.62]){const w=new THREE.Mesh(new THREE.CylinderGeometry(.27,.27,.17,18),mat(0x101820));w.rotation.z=Math.PI/2;w.position.set(x,.28,z);g.add(w);}
 for(const x of [-.48,.48])box(g,[x,.95,-1.1],[.12,1.85,.12],mat(0xe6a63b));
 box(g,[0,.13,-1.42],[1.2,.12,.85],mat(0xb7c6d2));
 const load=new THREE.Group();load.name="cargo";load.position.set(0,.25,-1.35);g.add(load);
 for(let i=0;i<3;i++)box(load,[0,.25+i*.42,0],[.82,.38,.72],mat([0x3c91a7,0x4b9b78,0xc28d45][i]));
 return g;
}
function makeTruck(x,z){
 const g=new THREE.Group();g.position.set(x,0,z);scene.add(g);
 box(g,[0,.75,0],[3.8,1.3,2.2],mat(0x9bb1c4));
 box(g,[-1.45,1.05,0],[1.1,1.9,2.25],mat(0x315b79));
 box(g,[-1.45,1.55,1.14],[.65,.65,.05],mat(0x8fd3e2,.3,.3));
 for(const wx of [-1.25,1.25])for(const wz of [-1,1]){const w=new THREE.Mesh(new THREE.CylinderGeometry(.42,.42,.22,20),mat(0x111820));w.rotation.z=Math.PI/2;w.position.set(wx,.4,wz);g.add(w);}
 return g;
}
function makeConveyor(){
 const g=new THREE.Group();g.position.set(8,0,7);scene.add(g);
 box(g,[0,.75,0],[6,.25,1.5],mat(0x354e61,.4,.5));
 for(let i=0;i<12;i++){const r=new THREE.Mesh(new THREE.CylinderGeometry(.09,.09,1.42,12),mat(0x8da5b6,.4,.65));r.rotation.z=Math.PI/2;r.position.set(-2.7+i*.49,.92,0);g.add(r);}
 box(g,[0,1.25,-.68],[6,.9,.12],mat(0x5b778d));box(g,[0,1.25,.68],[6,.9,.12],mat(0x5b778d));
 conveyorPackages=[];
 for(let i=0;i<4;i++){const p=new THREE.Group();p.position.set(-2.3+i*1.4,1.18,0);box(p,[0,0,0],[.72,.48,.62],mat(0xc28d45));box(p,[0,.25,0],[.76,.035,.66],mat(0xe7d4a9));g.add(p);conveyorPackages.push(p);}
 return g;
}
function buildScene(inventory){
 const w=sceneHost.clientWidth||900,h=sceneHost.clientHeight||600;
 scene=new THREE.Scene();scene.background=new THREE.Color(0x071421);scene.fog=new THREE.Fog(0x071421,38,88);
 camera=new THREE.PerspectiveCamera(43,w/h,.1,180);camera.position.set(23,20,27);
 renderer=new THREE.WebGLRenderer({antialias:true,alpha:false,powerPreference:"high-performance"});
 renderer.setPixelRatio(Math.min(window.devicePixelRatio||1,1.4));renderer.setSize(w,h);renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.12;renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
 sceneHost.replaceChildren(renderer.domElement);controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;controls.target.set(0,1.5,0);controls.maxPolarAngle=Math.PI/2.05;controls.minDistance=9;controls.maxDistance=58;
 scene.add(new THREE.HemisphereLight(0xc8e8ff,0x25394a,2));const key=new THREE.DirectionalLight(0xfff0d8,2.5);key.position.set(-12,25,15);key.castShadow=true;key.shadow.mapSize.set(1024,1024);scene.add(key);
 const fill=new THREE.PointLight(0x4aafcf,55,65);fill.position.set(15,14,-12);scene.add(fill);
 box(scene,[0,-.22,0],[43,.4,34],mat(0x172b3b));const grid=new THREE.GridHelper(42,42,0x31516a,0x20394d);grid.position.y=.01;scene.add(grid);
 const wall=mat(0x263e50,.8);box(scene,[0,5.2,-16.7],[43,10.4,.35],wall,false);box(scene,[-21.4,5.2,0],[.35,10.4,33],wall,false);box(scene,[21.4,5.2,0],[.35,10.4,33],wall,false);
 const beam=mat(0x3b566a,.5);for(let z=-14;z<=14;z+=7)box(scene,[0,9.5,z],[42,.2,.2],beam,false);
 // Inbound, QC, storage, picking, packing and dispatch zones.
 zone(-16,-10,7,7,0x1c9bb1);zone(-8,-10,6,7,0xd4a33e);zone(0,8,7,6,0x3c9d7c);zone(9,8,8,6,0x4d8ec1);zone(16,8,7,6,0x4b9a7d);
 const dock=mat(0x254b62,.55);for(let i=0;i<3;i++){const z=-12+i*6;box(scene,[-19,.35,z],[2,.7,2.8],dock);box(scene,[19,.35,z],[2,.7,2.8],dock);}
 stockMeshes=[];inventory.slice(0,5).forEach((item,i)=>addRack(-12+i*6,i,item));
 forklift=makeForklift();forklift.position.set(0,0,10);
 truck=makeTruck(-19,-10);truck.visible=true;
 // QC portal and animated scanner beam.
 const portal=new THREE.Group();portal.position.set(-8,0,-10);scene.add(portal);
 for(const x of [-1.35,1.35])box(portal,[x,2.1,0],[.14,4.2,.14],mat(0x8ba7b8,.35,.5));
 box(portal,[0,4.1,0],[2.8,.18,.18],mat(0x8ba7b8,.35,.5));
 scanBeam=box(portal,[0,2.1,.2],[2.3,.06,.06],mat(0x54e4e4,.25,.5));scanBeam.material.emissive=new THREE.Color(0x20caca);scanBeam.material.emissiveIntensity=1.8;scanBeam.visible=false;
 makeConveyor();
 // Packing workbench and pallet staging.
 box(scene,[8,1.05,4.4],[4.5,1.5,1.4],mat(0x405e72));for(let i=0;i<3;i++)box(scene,[6.7+i*1.3,1.9,4.4],[.85,.55,.8],mat(0xc28d45));
 renderer.domElement.addEventListener("pointerdown",onScenePointer);
 if(typeof ResizeObserver!=="undefined"){resizeObserver=new ResizeObserver(resizeScene);resizeObserver.observe(sceneHost);}
 updateStats(inventory);animate();
}
function updateStats(inventory){
 $("warehouse3dTotalUnits").textContent=inventory.reduce((s,x)=>s+Number(x.quantity||0),0).toLocaleString();
 $("warehouse3dSkuCount").textContent=String(inventory.length);
 $("warehouse3dLowCount").textContent=String(inventory.filter(x=>statusFor(x)==="critical").length);
 const list=$("warehouse3dInventoryList");list.replaceChildren();
 inventory.forEach((item,i)=>{const b=document.createElement("button");b.type="button";b.className="warehouse3d-item";const left=document.createElement("span"),dot=document.createElement("i"),name=document.createElement("b"),qty=document.createElement("small");dot.className="stock-dot "+statusFor(item);name.textContent=item.item_name||item.sku;qty.textContent=Number(item.quantity||0).toLocaleString()+" dona";left.append(dot,name);b.append(left,qty);b.addEventListener("click",()=>showItem(item,i));list.append(b);});
}
function showItem(item,index){
 const names={healthy:"Yetarli zaxira",warning:"Zaxira kamaymoqda",critical:"Qayta buyurtma kerak"},host=$("warehouse3dDetail");host.replaceChildren();
 const eyebrow=document.createElement("span");eyebrow.className="warehouse3d-eyebrow";eyebrow.textContent="SKU · "+(item.sku||"—");
 const title=document.createElement("h3");title.textContent=item.item_name||"Mahsulot";
 const desc=document.createElement("p");desc.textContent=names[statusFor(item)]+" · "+(item.item_type||"Ombor mahsuloti");
 const metrics=document.createElement("div");metrics.className="warehouse3d-quantity";
 const qty=document.createElement("b");qty.textContent=Number(item.quantity||0).toLocaleString()+" dona";
 const reorder=document.createElement("span");reorder.textContent="Qayta buyurtma: "+Number(item.reorder_level||0).toLocaleString();
 metrics.append(qty,reorder);host.append(eyebrow,title,desc,metrics);
 stockMeshes.forEach(m=>{m.material.emissive=new THREE.Color(m.userData.stock?.sku===item.sku?0x1e9dca:0x000000);m.material.emissiveIntensity=m.userData.stock?.sku===item.sku?.18:0;});
 selectedMesh=stockMeshes.find(m=>m.userData.stock?.sku===item.sku)||null;
 if(selectedMesh&&controls){const p=selectedMesh.getWorldPosition(new THREE.Vector3());controls.target.lerp(p,.4);}
}
function onScenePointer(e){
 const r=renderer.domElement.getBoundingClientRect(),p=new THREE.Vector2((e.clientX-r.left)/r.width*2-1,-((e.clientY-r.top)/r.height)*2+1),ray=new THREE.Raycaster();ray.setFromCamera(p,camera);
 const hit=ray.intersectObjects(stockMeshes,false)[0];if(hit?.object?.userData?.stock)showItem(hit.object.userData.stock,hit.object.userData.rack);
}
function interpolatePath(points,t){
 const scaled=t*(points.length-1),idx=Math.min(points.length-2,Math.floor(scaled)),f=scaled-idx,a=points[idx],b=points[idx+1];return a.map((v,i)=>v+(b[i]-v)*f);
}
function animateForklift(points,duration,done){
 const start=performance.now();motion={duration,start,update:t=>{const p=interpolatePath(points,t);forklift.position.set(p[0],p[1],p[2]);const next=interpolatePath(points,Math.min(1,t+.01));forklift.rotation.y=Math.atan2(next[0]-p[0],next[2]-p[2]);},done};
}
function animateCustom(duration,update,done){motion={duration,start:performance.now(),update,done};}
function runStep(index){
 if(busy||index!==completedSteps.size||index>=steps.length)return Promise.resolve(false);
 busy=true;const step=steps[index];setProcessStatus("Bajarilmoqda: "+step.uz+"…");renderProcessPanel();
 return new Promise(resolve=>{
  const finish=()=>{motion=null;busy=false;completedSteps.add(index);setProcessStatus("✓ "+step.uz+" bajarildi · "+step.event);renderProcessPanel();resolve(true);};
  if(index===0){
   truck.visible=true;truck.position.set(-23,0,-10);
   animateCustom(2600,t=>{truck.position.x=-23+6*t;forklift.position.set(-16*t,0,10-20*t);},finish);
  }else if(index===1){
   scanBeam.visible=true;animateCustom(2300,t=>{scanBeam.position.x=-1.05+2.1*t;scanBeam.material.emissiveIntensity=1+Math.sin(t*18)*.9;forklift.position.set(-16+8*t,0,-10);},()=>{scanBeam.visible=false;finish();});
  }else if(index===2){
   const rackX=-12+(Math.max(0,currentInventory.length-1)*3);
   animateForklift([[-8,0,-10],[rackX,0,-7],[rackX,0,4.5]],3300,finish);
  }else if(index===3){
   const rackX=-12+(Math.max(0,currentInventory.length-1)*3);animateForklift([[rackX,0,4.5],[-5,0,5],[0,0,8],[3,0,8]],3000,finish);
  }else if(index===4){
   animateCustom(3000,t=>{conveyorPackages.forEach((p,i)=>{p.position.x=-2.3+((i*1.4+t*5.2)%5.4);p.position.y=1.18+Math.sin(t*12+i)*.025;});},finish);
  }else{
   const startX=truck.position.x,startZ=truck.position.z;animateCustom(2800,t=>{truck.position.x=startX+(19-startX)*t;truck.position.z=startZ+(8-startZ)*t;},()=>{truck.position.set(19,0,8);finish();});
  }
 });
}
function renderProcessPanel(){
 const host=$("warehouse3dProcessPanel");if(!host)return;host.replaceChildren();
 const head=document.createElement("div");head.className="warehouse3d-process-head";
 const title=document.createElement("b");title.textContent="END-TO-END OMBOR JARAYONI";
 const count=document.createElement("span");count.textContent=completedSteps.size+"/"+steps.length+" bosqich";
 head.append(title,count);host.append(head);
 const progress=document.createElement("div");progress.className="warehouse3d-progress";const fill=document.createElement("i");fill.style.width=(completedSteps.size/steps.length*100)+"%";progress.append(fill);host.append(progress);
 const list=document.createElement("div");list.className="warehouse3d-process-list";
 steps.forEach((s,i)=>{
  const card=document.createElement("div");card.className="warehouse3d-process-card"+(completedSteps.has(i)?" is-done":i===completedSteps.size?" is-next":"");
  const meta=document.createElement("div");meta.className="warehouse3d-process-meta";const n=document.createElement("span");n.textContent=String(i+1).padStart(2,"0");const name=document.createElement("b");name.textContent=s.uz;const state=document.createElement("small");state.textContent=completedSteps.has(i)?"BAJARILDI":i===completedSteps.size?(busy?"JARAYONDA":"KEYINGI"):"KUTILMOQDA";meta.append(n,name,state);
  const desc=document.createElement("p");desc.textContent=s.desc;const button=document.createElement("button");button.type="button";button.className="secondary-button";button.textContent=completedSteps.has(i)?"✓ Bajarildi":i===completedSteps.size?(busy?"Jarayonda…":"Jarayonni boshlash"):"Oldingi bosqichni kuting";button.disabled=busy||i!==completedSteps.size;button.addEventListener("click",()=>runStep(i));card.append(meta,desc,button);list.append(card);
 });host.append(list);
 const actions=document.createElement("div");actions.className="warehouse3d-process-actions";
 const all=document.createElement("button");all.type="button";all.className="primary-button";all.textContent=busy?"Jarayon bajarilmoqda…":completedSteps.size===steps.length?"Barcha bosqichlar bajarildi":"▶ To‘liq siklni bajarish";all.disabled=busy||completedSteps.size===steps.length;all.addEventListener("click",async()=>{all.disabled=true;for(let i=completedSteps.size;i<steps.length;i++)await runStep(i);}); 
 const reset=document.createElement("button");reset.type="button";reset.className="secondary-button";reset.textContent="Simulyatsiyani qayta boshlash";reset.disabled=busy||completedSteps.size===0;reset.addEventListener("click",resetSimulation);actions.append(all,reset);host.append(actions);
 const note=document.createElement("p");note.className="warehouse3d-simulation-note";note.textContent="O‘quv simulyatsiyasi: jarayonlar 3D sahnada animatsiya qilinadi. Bu bosqichlar hozircha Supabase’dagi zaxira, purchase order yoki shipment yozuvlarini o‘zgartirmaydi.";host.append(note);
}
function setProcessStatus(value){const el=$("warehouse3dProcessStatus");if(el)el.textContent=value;}
function resetSimulation(){
 completedSteps.clear();if(truck)truck.position.set(-19,0,-10);if(forklift)forklift.position.set(0,0,10);if(scanBeam)scanBeam.visible=false;
 conveyorPackages.forEach((p,i)=>p.position.set(-2.3+i*1.4,1.18,0));setProcessStatus("Jarayon boshlashga tayyor.");renderProcessPanel();
}
function animate(){
 animationFrame=requestAnimationFrame(animate);
 if(motion){const t=Math.min(1,(performance.now()-motion.start)/motion.duration);motion.update(t);if(t>=1){const done=motion.done;motion=null;done?.();}}
 controls?.update();renderer?.render(scene,camera);
}
function resizeScene(){if(!renderer||!camera)return;const w=sceneHost.clientWidth,h=sceneHost.clientHeight;if(!w||!h)return;camera.aspect=w/h;camera.updateProjectionMatrix();renderer.setSize(w,h,false);}
function destroyScene(){
 cancelAnimationFrame(animationFrame);resizeObserver?.disconnect();resizeObserver=null;motion=null;
 if(renderer){renderer.domElement.removeEventListener("pointerdown",onScenePointer);renderer.dispose();renderer.forceContextLoss();}
 controls?.dispose();renderer=null;scene=null;camera=null;controls=null;forklift=null;truck=null;scanBeam=null;stockMeshes=[];selectedMesh=null;conveyorPackages=[];
}
function openWarehouse(){
 const live=Array.isArray(window.supplyChainWarehouseInventory)&&window.supplyChainWarehouseInventory.length>0;
 currentInventory=live?window.supplyChainWarehouseInventory:defaultInventory;completedSteps.clear();busy=false;
 $("warehouse3dStatus").textContent=(live?"LIVE TEAM INVENTORY · "+(window.supplyChainWarehouseTeamName||"Jamoa"):"NAMUNAVIY KO‘RINISH · Demo zaxira")+" · 3D jarayonlar simulyatsiyasi";
 $("warehouse3dProcessStatus").textContent="Jarayon boshlashga tayyor.";
 document.body.classList.add("warehouse3d-open");workspace.hidden=false;
 try{if(renderer)destroyScene();buildScene(currentInventory);if(currentInventory[0])showItem(currentInventory[0],0);renderProcessPanel();}
 catch(error){console.error("Warehouse 3D initialization failed",error);sceneHost.textContent="3D sahnani yuklab bo‘lmadi. Qurilmangiz WebGL’ni qo‘llashini va internet aloqasini tekshiring. "+error.message;}
}
function closeWarehouse(){document.body.classList.remove("warehouse3d-open");workspace.hidden=true;destroyScene();document.querySelector("#competitionWorkspace")?.scrollIntoView({behavior:"smooth",block:"start"});}
entryButton?.addEventListener("click",openWarehouse);
$("warehouse3dBackButton")?.addEventListener("click",closeWarehouse);
$("warehouse3dResetButton")?.addEventListener("click",()=>{if(!camera||!controls)return;camera.position.set(23,20,27);controls.target.set(0,1.5,0);controls.update();});
window.addEventListener("pagehide",destroyScene);
