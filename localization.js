const UI_UZ = new Map(Object.entries({
"Loading…":"Yuklanmoqda…","Loading data…":"Ma’lumotlar yuklanmoqda…","Refresh":"Yangilash","Save":"Saqlash","Cancel":"Bekor qilish","Delete":"O‘chirish","Edit":"Tahrirlash","Submit":"Yuborish","Create":"Yaratish","Update":"Yangilash","Back":"Orqaga","Next":"Keyingi","Previous":"Oldingi","Search":"Qidirish","Filter":"Saralash","All":"Barchasi","Status":"Holat","Actions":"Amallar","Name":"Nomi","Role":"Rol","Date":"Sana","Time":"Vaqt","Quantity":"Miqdor","Unit cost":"Birlik narxi","Total cost":"Umumiy xarajat","Supplier":"Yetkazib beruvchi","Customer":"Mijoz","Warehouse":"Ombor","Manufacturer":"Ishlab chiqaruvchi","Transport":"Transport","Retailer":"Chakana sotuvchi","In progress":"Jarayonda","Pending":"Kutilmoqda","Approved":"Tasdiqlangan","Rejected":"Rad etilgan","Completed":"Yakunlangan","Active":"Faol","Paused":"To‘xtatilgan","Draft":"Qoralama","Open":"Ochiq","Closed":"Yopiq","No data available":"Ma’lumot mavjud emas","No records yet.":"Hozircha yozuvlar yo‘q.","No items found.":"Hech narsa topilmadi.","Try again":"Qayta urinib ko‘ring","Classroom":"O‘quv guruhi","Classrooms":"O‘quv guruhlari","Inventory":"Ombor zaxiralari","Operations":"Operatsiyalar","Procurement":"Xaridlar","Analytics":"Tahlillar","Competition":"Musobaqa","Orders":"Buyurtmalar","Shipments":"Yuk jo‘natmalari","Purchase orders":"Xarid buyurtmalari","Stock level":"Zaxira darajasi","Reorder point":"Qayta buyurtma nuqtasi","Lead time":"Yetkazib berish muddati","On-time delivery":"O‘z vaqtida yetkazish","Service level":"Xizmat darajasi","Create order":"Buyurtma yaratish","Create shipment":"Yuk jo‘natmasi yaratish","Receive stock":"Tovarni qabul qilish","Issue stock":"Tovarni chiqarish","Add supplier":"Yetkazib beruvchi qo‘shish","Launch scenario":"Ssenariyni boshlash","Submit decision":"Qarorni yuborish","Evaluate":"Baholash","Feedback":"Izoh","Score":"Ball","Due date":"Muddat","Team name":"Jamoa nomi","Student":"Talaba","Teacher":"O‘qituvchi","Sign in":"Kirish","Sign out":"Chiqish","Welcome back":"Xush kelibsiz","My workspace":"Mening ish maydonim","Overall overview":"Umumiy ko‘rinish","Global overview":"Umumiy ko‘rinish","Network map":"Ta’minot tarmog‘i xaritasi","Digital layer":"Raqamli qatlam","Physical layer":"Jismoniy qatlam","Run disruption scenario":"Uzilish ssenariysini ishga tushirish","Restore normal operations":"Normal faoliyatni tiklash","Simulation active":"Simulyatsiya faol","Demo environment":"Namoyish muhiti","No competition selected":"Musobaqa tanlanmagan","No tasks yet.":"Hozircha topshiriqlar yo‘q.","No decisions yet.":"Hozircha qarorlar yo‘q.","No operational scores yet.":"Hozircha operatsion ballar yo‘q.","Create a competition":"Musobaqa yaratish","Start competition":"Musobaqani boshlash","Pause competition":"Musobaqani to‘xtatish","Add team":"Jamoa qo‘shish","Assign task":"Topshiriq berish","Generate task pack":"Topshiriqlar to‘plamini yaratish","Individual contribution ranking":"Shaxsiy hissalar reytingi","Student decisions & evaluation":"Talabalar qarorlari va baholash","Your company team":"Sizning kompaniya jamoangiz","Your assigned role":"Sizga biriktirilgan rol","Supplier management":"Yetkazib beruvchilarni boshqarish","Orders & shipments":"Buyurtmalar va yuklar","Scenario lab":"Ssenariy laboratoriyasi","Team competition":"Jamoaviy musobaqa"
}));
function translateNode(node){
 if(node.nodeType===Node.TEXT_NODE){
  const raw=node.nodeValue, key=raw.trim();
  if(UI_UZ.has(key)) node.nodeValue=raw.replace(key,UI_UZ.get(key));
 } else if(node.nodeType===Node.ELEMENT_NODE){
  for(const attr of ["placeholder","title","aria-label"]){
   const value=node.getAttribute(attr);
   if(value&&UI_UZ.has(value)) node.setAttribute(attr,UI_UZ.get(value));
  }
 }
}
function translateTree(root){
 translateNode(root);
 root.querySelectorAll?.("*").forEach(translateNode);
}
translateTree(document.documentElement);
new MutationObserver(records=>{
 for(const record of records){
  if(record.type==="characterData") translateNode(record.target);
  else record.addedNodes.forEach(node=>translateTree(node));
 }
}).observe(document.documentElement,{subtree:true,childList:true,characterData:true});
document.documentElement.lang="uz";
