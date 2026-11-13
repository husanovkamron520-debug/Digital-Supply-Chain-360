import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const root = document.querySelector("#procurementWorkspace");
if (root && SUPABASE_URL.startsWith("https://") && !SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  const db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const classSelect = document.querySelector("#procurementClassSelect");
  const supplierForm = document.querySelector("#createSupplierForm");
  const poForm = document.querySelector("#createPurchaseOrderForm");
  const suppliersList = document.querySelector("#suppliersList");
  const ordersList = document.querySelector("#purchaseOrdersList");
  const supplierSelect = document.querySelector("#poSupplier");
  const note = document.querySelector("#procurementAccessNote");
  const message = document.querySelector("#procurementMessage");
  let user = null, isTeacher = false, activeClassId = null, roleByClass = {};

  const el = (tag, cls, value) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (value !== undefined) n.textContent = value;
    return n;
  };
  const option = (label, value) => { const n=el("option","",label); n.value=value; return n; };
  const say = (value, success=false) => { message.textContent=value; message.classList.toggle("success",success); };
  const role = () => roleByClass[activeClassId] || "";
  const canSupplier = () => isTeacher || role()==="supplier";
  const canCreatePO = () => isTeacher || role()==="manufacturer";
  const canReceive = () => isTeacher || role()==="warehouse";
  const dateText = value => value ? new Date(value).toLocaleDateString() : "No expected date";

  function applyPermissions() {
    supplierForm.hidden = !canSupplier();
    poForm.hidden = !canCreatePO();
    note.textContent = isTeacher
      ? "Teacher mode · manage suppliers, create purchase orders, and receive stock."
      : role()==="supplier"
        ? "Supplier role · register your supplier profile to receive and respond to purchase orders assigned to you."
        : role()==="manufacturer"
          ? "Manufacturer role · create purchase orders from registered suppliers."
          : "Warehouse role · receive stock after the supplier accepts the purchase order.";
  }

  async function loadSuppliers() {
    const {data,error}=await db.from("suppliers").select("id,supplier_code,name,lead_time_days,status,supplier_user_id")
      .eq("classroom_id",activeClassId).order("name");
    if(error) throw error;
    suppliersList.replaceChildren();
    supplierSelect.replaceChildren();
    if(!data.length) suppliersList.append(el("p","empty-state","No suppliers registered yet."));
    if(!data.length) supplierSelect.append(option("Register a supplier first",""));
    for(const supplier of data){
      const card=el("div","procurement-record");
      const head=el("div","procurement-record-head");
      const title=el("div","procurement-record-title");
      title.append(el("b","",supplier.name),el("small","",supplier.supplier_code+" · "+supplier.lead_time_days+" day lead time"+(supplier.supplier_user_id===user.id?" · Your supplier account":"")));
      head.append(title,el("span","procurement-status "+supplier.status,supplier.status.toUpperCase()));
      card.append(head); suppliersList.append(card);
      if(supplier.status==="active") supplierSelect.append(option(supplier.name+" · "+supplier.supplier_code,supplier.id));
    }
    if(!data.some(s=>s.status==="active")) supplierSelect.append(option("No active supplier available",""));
  }

  async function loadPurchaseOrders() {
    const {data,error}=await db.from("purchase_orders")
      .select("id,po_number,sku,item_name,quantity,received_quantity,unit_cost,status,supplier_response,supplier_note,supplier_responded_at,expected_at,created_at,suppliers(name,supplier_code,supplier_user_id)")
      .eq("classroom_id",activeClassId).order("created_at",{ascending:false}).limit(50);
    if(error) throw error;
    ordersList.replaceChildren();
    if(!data.length) ordersList.append(el("p","empty-state","No purchase orders yet."));
    for(const po of data){
      const card=el("article","procurement-record");
      const head=el("div","procurement-record-head");
      const title=el("div","procurement-record-title");
      title.append(el("b","",po.po_number+" · "+po.item_name),el("small","",(po.suppliers?.name||"Supplier")+" · "+po.sku));
      head.append(title,el("span","procurement-status "+po.status,po.status.replaceAll("_"," ").toUpperCase()));
      card.append(head);
      const progress=po.received_quantity+" / "+po.quantity+" units received";
      card.append(el("div","procurement-progress-label",progress));
      card.append(el("div","procurement-response-label",po.suppliers?.supplier_user_id?"Supplier response · "+(po.supplier_response||"pending").toUpperCase()+(po.supplier_note?" · "+po.supplier_note:""):"Supplier account · not linked"));
      const track=el("div","procurement-progress");
      const bar=el("i");
      bar.style.width=Math.min(100,po.received_quantity/po.quantity*100)+"%";
      track.append(bar); card.append(track);
      const meta=el("div","procurement-record-meta");
      meta.append(el("span","","Unit cost · "+Number(po.unit_cost).toFixed(2)));
      meta.append(el("span","","Expected · "+dateText(po.expected_at)));
      card.append(meta);
      if(role()==="supplier" && po.suppliers?.supplier_user_id===user.id && po.status==="placed" && po.supplier_response==="pending"){
        const responseActions=el("div","procurement-supplier-actions");
        for(const [response,label] of [["accepted","Accept purchase order"],["rejected","Reject purchase order"]]){
          const responseButton=el("button",response==="accepted"?"procurement-accept-button":"procurement-reject-button",label);
          responseButton.type="button";
          responseButton.addEventListener("click",async()=>{
            responseButton.disabled=true;
            try{
              const {error:responseError}=await db.rpc("respond_to_purchase_order",{
                p_purchase_order_id:po.id,p_response:response,
                p_note:response==="accepted"?"Accepted by supplier":"Supplier cannot fulfil this order"
              });
              if(responseError)throw responseError;
              say("Purchase order "+response+".",true);
              await loadPurchaseOrders();
            }catch(error){say(error.message);responseButton.disabled=false;}
          });
          responseActions.append(responseButton);
        }
        card.append(responseActions);
      }
      if(isTeacher && po.status==="placed" && po.received_quantity===0){
        const cancel=el("button","procurement-cancel-button","Cancel purchase order");
        cancel.type="button";
        cancel.addEventListener("click",async()=>{
          cancel.disabled=true;
          try{
            const {error:cancelError}=await db.rpc("cancel_purchase_order",{p_purchase_order_id:po.id});
            if(cancelError) throw cancelError;
            say("Purchase order cancelled.",true);
            await loadPurchaseOrders();
          }catch(error){say(error.message);cancel.disabled=false;}
        });
        card.append(cancel);
      }
      if(canReceive() && ["placed","partially_received"].includes(po.status) && (isTeacher || !po.suppliers?.supplier_user_id || po.supplier_response==="accepted")){
        const receiveForm=el("form","procurement-receive-form");
        const qty=el("input",""); qty.type="number"; qty.min="1"; qty.max=String(po.quantity-po.received_quantity); qty.value=qty.max; qty.required=true;
        qty.setAttribute("aria-label","Quantity received");
        const btn=el("button","procurement-receive-button","Receive stock"); btn.type="submit";
        receiveForm.append(qty,btn);
        receiveForm.addEventListener("submit",async event=>{
          event.preventDefault(); btn.disabled=true;
          try{
            const {data:result,error:receiveError}=await db.rpc("receive_purchase_order",{p_purchase_order_id:po.id,p_quantity:Number(qty.value)});
            if(receiveError) throw receiveError;
            say("Received "+qty.value+" units. Inventory is now "+result.stock_quantity+".",true);
            await loadPurchaseOrders();
          }catch(error){say(error.message);btn.disabled=false;}
        });
        card.append(receiveForm);
      }
      ordersList.append(card);
    }
  }

  async function loadClassrooms(){
    let classes=[];
    if(isTeacher){
      const {data,error}=await db.from("classrooms").select("id,name").eq("teacher_id",user.id).order("created_at",{ascending:false});
      if(error) throw error; classes=data||[];
    }else{
      const {data,error}=await db.from("classroom_members").select("operational_role,classrooms(id,name)").eq("student_id",user.id);
      if(error) throw error;
      for(const row of data||[]){if(row.classrooms){classes.push(row.classrooms);roleByClass[row.classrooms.id]=row.operational_role;}}
    }
    classSelect.replaceChildren();
    for(const c of classes) classSelect.append(option(c.name,c.id));
    if(!classes.length){
      activeClassId=null; supplierForm.hidden=true; poForm.hidden=true;
      suppliersList.replaceChildren(el("p","empty-state","Join a classroom to use procurement."));
      ordersList.replaceChildren(); return;
    }
    activeClassId=classes[0].id; classSelect.value=activeClassId;
    applyPermissions();
    await loadSuppliers(); await loadPurchaseOrders();
  }

  async function initialize(session){
    if(!session?.user){root.hidden=true;return;}
    user=session.user;
    try{
      const {data:profile,error}=await db.from("profiles").select("platform_role").eq("id",user.id).single();
      if(error) throw error;
      isTeacher=profile.platform_role==="teacher";
      if(!isTeacher){
        const {data,error:membershipError}=await db.from("classroom_members").select("operational_role").eq("student_id",user.id);
        if(membershipError) throw membershipError;
        if(!(data||[]).some(m=>["supplier","manufacturer","warehouse"].includes(m.operational_role))){root.hidden=true;return;}
      }
      root.hidden=false; await loadClassrooms();
    }catch(error){root.hidden=false;say("Procurement could not load: "+error.message);}
  }

  classSelect.addEventListener("change",async()=>{
    activeClassId=classSelect.value;applyPermissions();
    try{await loadSuppliers();await loadPurchaseOrders();say("");}catch(error){say(error.message);}
  });

  supplierForm.addEventListener("submit",async event=>{
    event.preventDefault();if(!activeClassId||!canSupplier())return;
    const btn=supplierForm.querySelector("button");btn.disabled=true;
    try{
      const {error}=await db.rpc("create_supplier",{
        p_classroom_id:activeClassId,p_supplier_code:document.querySelector("#supplierCode").value.trim(),
        p_name:document.querySelector("#supplierName").value.trim(),p_lead_time_days:Number(document.querySelector("#supplierLeadTime").value)
      });
      if(error)throw error;supplierForm.reset();document.querySelector("#supplierLeadTime").value="7";
      say("Supplier registered.",true);await loadSuppliers();
    }catch(error){say(error.message);}finally{btn.disabled=false;}
  });

  poForm.addEventListener("submit",async event=>{
    event.preventDefault();if(!activeClassId||!canCreatePO())return;
    const btn=poForm.querySelector("button");btn.disabled=true;
    try{
      const expected=document.querySelector("#poExpectedAt").value;
      const {error}=await db.rpc("create_purchase_order",{
        p_classroom_id:activeClassId,p_supplier_id:supplierSelect.value,
        p_po_number:document.querySelector("#poNumber").value.trim(),p_sku:document.querySelector("#poSku").value.trim(),
        p_item_name:document.querySelector("#poItemName").value.trim(),p_quantity:Number(document.querySelector("#poQuantity").value),
        p_unit_cost:Number(document.querySelector("#poUnitCost").value),p_expected_at:expected?new Date(expected).toISOString():null
      });
      if(error)throw error;poForm.reset();document.querySelector("#poQuantity").value="100";document.querySelector("#poUnitCost").value="0";
      say("Purchase order created.",true);await loadPurchaseOrders();
    }catch(error){say(error.message);}finally{btn.disabled=false;}
  });

  db.auth.getSession().then(({data})=>initialize(data.session));
  db.auth.onAuthStateChange((_event,session)=>{if(session)setTimeout(()=>initialize(session),0);else{root.hidden=true;user=null;activeClassId=null;}});
}
