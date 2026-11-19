import * as THREE from "three";
import { OrbitControls } from "https://cdn.jsdelivr.net/npm/three@0.169.0/examples/jsm/controls/OrbitControls.js";

const $ = (id) => document.getElementById(id);
const entryButton = $("warehouse3dOpenButton");
const workspace = $("warehouse3dWorkspace");
const sceneHost = $("warehouse3dScene");
let renderer = null, scene = null, camera = null, controls = null, animationFrame = 0;
let resizeObserver = null, stockMeshes = [], currentInventory = [], selectedMesh = null;
const defaultInventory = [
  {sku:"SKU-01",item_name:"Wireless Earbuds",quantity:500,reorder_level:180,unit_cost:12},
  {sku:"SKU-02",item_name:"Wireless Mouse",quantity:700,reorder_level:220,unit_cost:8},
  {sku:"SKU-03",item_name:"Smart Watch",quantity:300,reorder_level:120,unit_cost:28},
  {sku:"SKU-04",item_name:"Coffee Maker",quantity:200,reorder_level:80,unit_cost:35},
  {sku:"SKU-05",item_name:"Ergonomic Office Chair",quantity:150,reorder_level:60,unit_cost:48}
];
const palette = {healthy:0x21b98a,warning:0xe6a93d,critical:0xe45c68};
function statusFor(item){
  const qty=Number(item.quantity)||0, reorder=Number(item.reorder_level)||0;
  if(qty<=reorder)return "critical";
  if(qty<=reorder*1.5)return "warning";
  return "healthy";
}
function material(color,roughness=0.78){return new THREE.MeshStandardMaterial({color,roughness,metalness:0.12});}
function addBox(parent,position,size,mat,cast=true){
  const mesh=new THREE.Mesh(new THREE.BoxGeometry(size[0],size[1],size[2]),mat);
  mesh.position.set(position[0],position[1],position[2]);mesh.castShadow=cast;mesh.receiveShadow=true;parent.add(mesh);return mesh;
}
function addRack(x,index,item){
  const rack=new THREE.Group();rack.position.x=x;scene.add(rack);
  const steel=material(0x60798e,0.42),beam=material(0x9aafbf,0.48),deck=material(0x31495d,0.62);
  const width=2.9,depth=10.4,front=-5.2,back=5.2;
  for(const z of [front,back]){
    for(const dx of [-width/2,width/2])addBox(rack,[dx,2.5,z],[0.16,5,0.16],steel);
  }
  for(let level=0;level<4;level++){
    const y=0.8+level*1.28;
    addBox(rack,[0,y,0],[width,0.12,depth],deck);
    for(const z of [front,back])addBox(rack,[0,y+0.16,z],[width+0.12,0.22,0.16],beam);
    for(let bay=0;bay<4;bay++){
      const z=front+1.25+bay*2.45;
      const qty=Math.max(0,Number(item.quantity)||0);
      const perBox=qty/12;
      const fill=Math.min(1,perBox/Math.max(1,(Number(item.reorder_level)||1)/12*1.8));
      const height=0.32+fill*0.58;
      const box=addBox(rack,[0,y+0.24+height/2,z],[1.55,height,1.12],material(palette[statusFor(item)],0.55));
      box.userData.stock=item;box.userData.rack=index;box.userData.bay=bay+1;box.userData.level=level+1;
      stockMeshes.push(box);
      const stripe=addBox(rack,[0,y+0.24+height/2,z+0.57],[1.58,0.045,0.035],material(0xe4edf4,0.6),false);
      stripe.userData.stock=item;stripe.userData.rack=index;stripe.userData.bay=bay+1;stripe.userData.level=level+1;
      stockMeshes.push(stripe);
    }
  }
  // Upright diagonal bracing adds depth and makes the rack structure readable.
  for(const z of [front+0.25,back-0.25]){
    const brace=addBox(rack,[0,2.45,z],[0.07,4.6,0.07],material(0x8ca2b4,0.5));
    brace.rotation.z=0.34;
  }
}
function buildScene(inventory){
  const width=sceneHost.clientWidth||900,height=sceneHost.clientHeight||600;
  scene=new THREE.Scene();scene.background=new THREE.Color(0x071421);scene.fog=new THREE.Fog(0x071421,32,78);
  camera=new THREE.PerspectiveCamera(43,width/height,0.1,180);camera.position.set(18,17,23);
  renderer=new THREE.WebGLRenderer({antialias:true,alpha:false,powerPreference:"high-performance"});
  renderer.setPixelRatio(Math.min(window.devicePixelRatio||1,1.5));renderer.setSize(width,height);
  renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.15;
  renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
  sceneHost.replaceChildren(renderer.domElement);
  controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;controls.dampingFactor=0.065;
  controls.minDistance=8;controls.maxDistance=52;controls.maxPolarAngle=Math.PI/2.05;controls.target.set(0,1.8,0);
  scene.add(new THREE.HemisphereLight(0xc8e8ff,0x26394a,2.1));
  const key=new THREE.DirectionalLight(0xfff0d8,2.5);key.position.set(-12,24,14);key.castShadow=true;key.shadow.mapSize.set(1024,1024);scene.add(key);
  const fill=new THREE.PointLight(0x4aafcf,45,55);fill.position.set(15,12,-12);scene.add(fill);
  const floor=addBox(scene,[0,-0.22,0],[39,0.4,30],material(0x172b3b));floor.receiveShadow=true;
  const grid=new THREE.GridHelper(38,38,0x31516a,0x20394d);grid.position.y=-0.005;scene.add(grid);
  const wallMat=material(0x263e50,0.8);
  addBox(scene,[0,5.2,-14.6],[39,10.4,0.35],wallMat,false);
  addBox(scene,[-19.4,5.2,0],[0.35,10.4,29],wallMat,false);
  addBox(scene,[19.4,5.2,0],[0.35,10.4,29],wallMat,false);
  const roofBeam=material(0x3b566a,0.5);
  for(let z=-12;z<=12;z+=6)addBox(scene,[0,9.5,z],[38,0.22,0.22],roofBeam,false);
  // Five rack rows, each representing one SKU in the selected case.
  // Receiving and dispatch docks.
  const dock=material(0x254b62,0.55);
  for(let i=0;i<3;i++){
    const z=-8+i*6;
    addBox(scene,[-17.2,0.35,z],[2.4,0.7,3.1],dock);
    addBox(scene,[17.2,0.35,z],[2.4,0.7,3.1],dock);
  }
  // Simple forklift parked in the central aisle.
  const truck= new THREE.Group();truck.position.set(0,0,9);scene.add(truck);
  addBox(truck,[0,0.62,0],[1.45,0.85,2.05],material(0xe0a33d));
  addBox(truck,[0,1.48,-0.3],[1.15,0.9,0.1],material(0x263a4b));
  for(const x of [-0.55,0.55])for(const z of [-0.65,0.65]){
    const wheel=new THREE.Mesh(new THREE.CylinderGeometry(0.28,0.28,0.16,16),material(0x111a22));
    wheel.rotation.z=Math.PI/2;wheel.position.set(x,0.28,z);truck.add(wheel);
  }
  addBox(truck,[0.52,0.9,-1.2],[0.12,1.7,0.12],material(0xe0a33d));
  addBox(truck,[0.95,0.9,-1.2],[0.12,1.7,0.12],material(0xe0a33d));
  stockMeshes=[];
  inventory.slice(0,5).forEach((item,index)=>addRack(-14+index*7,index,item));
  const axes=new THREE.AxesHelper(0);axes.visible=false;scene.add(axes);
  renderer.domElement.addEventListener("pointerdown",onScenePointer);
  resizeObserver=new ResizeObserver(resizeScene);resizeObserver.observe(sceneHost);
  updateStats(inventory);
  animate();
}
function updateStats(inventory){
  const total=inventory.reduce((sum,item)=>sum+Number(item.quantity||0),0);
  $("warehouse3dTotalUnits").textContent=total.toLocaleString();
  $("warehouse3dSkuCount").textContent=String(inventory.length);
  $("warehouse3dLowCount").textContent=String(inventory.filter(x=>statusFor(x)==="critical").length);
  const list=$("warehouse3dInventoryList");list.replaceChildren();
  inventory.forEach((item,index)=>{
    const button=document.createElement("button");button.type="button";button.className="warehouse3d-item";
    const left=document.createElement("span"),dot=document.createElement("i"),name=document.createElement("b"),qty=document.createElement("small");
    dot.className="stock-dot "+statusFor(item);name.textContent=item.item_name||item.sku;qty.textContent=Number(item.quantity||0).toLocaleString()+" dona";
    left.append(dot,name);button.append(left,qty);button.addEventListener("click",()=>showItem(item,index));list.append(button);
  });
}
function showItem(item,index){
  const status=statusFor(item),names={healthy:"Yetarli zaxira",warning:"Zaxira kamaymoqda",critical:"Qayta buyurtma kerak"};
  $("warehouse3dDetail").innerHTML="";
  const eyebrow=document.createElement("span");eyebrow.className="warehouse3d-eyebrow";eyebrow.textContent="SKU · "+(item.sku||"—");
  const title=document.createElement("h3");title.textContent=item.item_name||"Mahsulot";
  const desc=document.createElement("p");desc.textContent=names[status]+" · "+(item.item_type||"Ombor mahsuloti");
  const metrics=document.createElement("div");metrics.className="warehouse3d-quantity";
  const quantity=document.createElement("b");quantity.textContent=Number(item.quantity||0).toLocaleString()+" dona";
  const reorder=document.createElement("span");reorder.textContent="Qayta buyurtma: "+Number(item.reorder_level||0).toLocaleString();
  metrics.append(quantity,reorder);$("warehouse3dDetail").append(eyebrow,title,desc,metrics);
  stockMeshes.forEach(mesh=>{if(mesh.userData.stock?.sku===item.sku){mesh.material.emissive=new THREE.Color(0x1e9dca);mesh.material.emissiveIntensity=0.16;}else{mesh.material.emissiveIntensity=0;}});
  selectedMesh=stockMeshes.find(mesh=>mesh.userData.stock?.sku===item.sku)||null;
  if(selectedMesh){const p=selectedMesh.getWorldPosition(new THREE.Vector3());controls.target.lerp(p,0.45);}
}
function onScenePointer(event){
  const rect=renderer.domElement.getBoundingClientRect();
  const pointer=new THREE.Vector2((event.clientX-rect.left)/rect.width*2-1,-((event.clientY-rect.top)/rect.height)*2+1);
  const raycaster=new THREE.Raycaster();raycaster.setFromCamera(pointer,camera);
  const hit=raycaster.intersectObjects(stockMeshes,false)[0];
  if(hit?.object?.userData?.stock)showItem(hit.object.userData.stock,hit.object.userData.rack);
}
function animate(){
  animationFrame=requestAnimationFrame(animate);
  controls?.update();renderer?.render(scene,camera);
}
function resizeScene(){
  if(!renderer||!camera)return;
  const w=sceneHost.clientWidth,h=sceneHost.clientHeight;if(!w||!h)return;
  camera.aspect=w/h;camera.updateProjectionMatrix();renderer.setSize(w,h,false);
}
function destroyScene(){
  cancelAnimationFrame(animationFrame);resizeObserver?.disconnect();resizeObserver=null;
  if(renderer){renderer.domElement.removeEventListener("pointerdown",onScenePointer);renderer.dispose();renderer.forceContextLoss();}
  controls?.dispose();renderer=null;scene=null;camera=null;controls=null;stockMeshes=[];selectedMesh=null;
}
function openWarehouse(){
  const live=Array.isArray(window.supplyChainWarehouseInventory)&&window.supplyChainWarehouseInventory.length>0;
  currentInventory=live?window.supplyChainWarehouseInventory:defaultInventory;
  $("warehouse3dStatus").textContent=live
    ?"LIVE TEAM INVENTORY · "+(window.supplyChainWarehouseTeamName||"Jamoa")+(window.supplyChainWarehouseTeamId?" · "+String(window.supplyChainWarehouseTeamId).slice(0,8):"")
    :"NAMUNAVIY KO‘RINISH · Hozircha jamoa zaxirasi ulanmagan";
  document.body.classList.add("warehouse3d-open");workspace.hidden=false;
  if(renderer)destroyScene();
  buildScene(currentInventory);
  if(currentInventory[0])showItem(currentInventory[0],0);
}
function closeWarehouse(){
  document.body.classList.remove("warehouse3d-open");workspace.hidden=true;
  document.querySelector("#competitionWorkspace")?.scrollIntoView({behavior:"smooth",block:"start"});
}
entryButton?.addEventListener("click",openWarehouse);
$("warehouse3dBackButton")?.addEventListener("click",closeWarehouse);
$("warehouse3dResetButton")?.addEventListener("click",()=>{
  if(!camera||!controls)return;camera.position.set(18,17,23);controls.target.set(0,1.8,0);controls.update();
});
window.addEventListener("pagehide",destroyScene);
