import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const gate = document.querySelector("#authGate");
const form = document.querySelector("#authForm");
const title = document.querySelector("#authTitle");
const subtitle = document.querySelector("#authSubtitle");
const nameInput = document.querySelector("#authName");
const nameLabel = document.querySelector("#authNameLabel");
const emailInput = document.querySelector("#authEmail");
const passwordInput = document.querySelector("#authPassword");
const submit = document.querySelector("#authSubmit");
const message = document.querySelector("#authMessage");
const switchText = document.querySelector("#authSwitchText");
const switchButton = document.querySelector("#authSwitch");
const appShell = document.querySelector(".app-shell");
let mode = "login";
let supabase = null;

function showMessage(text, success = false) {
  message.textContent = text;
  message.classList.toggle("success", success);
}
function setMode(nextMode) {
  mode = nextMode;
  const registering = mode === "register";
  title.textContent = registering ? "Create your account" : "Welcome back";
  subtitle.textContent = registering
    ? "Register as a student, then join your classroom with its code."
    : "Sign in to enter your classroom workspace.";
  nameInput.hidden = !registering;
  nameLabel.hidden = !registering;
  nameInput.required = registering;
  passwordInput.autocomplete = registering ? "new-password" : "current-password";
  submit.textContent = registering ? "Create student account" : "Sign in";
  switchText.textContent = registering ? "Already have an account?" : "New to the platform?";
  switchButton.textContent = registering ? "Sign in" : "Create student account";
  showMessage("");
}
function showApp(user, profile) {
  const fullName = profile?.full_name || user.user_metadata?.full_name || user.email?.split("@")[0] || "User";
  const role = profile?.platform_role || "student";
  gate.hidden = true;
  appShell?.classList.remove("auth-locked");
  document.querySelector("#userRole").textContent = role.toUpperCase();
  document.querySelector("#userAvatar").textContent = fullName.trim().charAt(0).toUpperCase();
  document.querySelector("#sidebarUserName").textContent = fullName;
  document.querySelector("#sidebarUserRole").textContent = role === "teacher" ? "Teacher workspace" : "Student workspace";
  document.querySelector("#todayLabel").textContent = new Intl.DateTimeFormat("en", {weekday:"long", day:"numeric", month:"long", year:"numeric"}).format(new Date()).toUpperCase();
  document.body.dataset.platformRole = role;
}
function setWorkspaceNavVisible(href, visible) {
  document.querySelectorAll(`.nav-link[href="${href}"]`).forEach(link => {
    link.hidden = !visible;
  });
}

async function syncWorkspaceNavigation(user, profile) {
  const teacher = profile?.platform_role === "teacher";
  if (teacher) {
    document.body.dataset.myWorkspaceTargets = JSON.stringify(["#teacherAnalytics", "#inventoryWorkspace", "#operationsWorkspace", "#procurementWorkspace", "#scenarioWorkspace"]);
    document.body.dataset.myWorkspaceTarget = "#teacherAnalytics";
    setWorkspaceNavVisible("#operationsWorkspace", true);
    setWorkspaceNavVisible("#procurementWorkspace", true);
    return;
  }

  const {data, error} = await supabase.from("classroom_members")
    .select("operational_role").eq("student_id", user.id);
  if (error) {
    document.body.dataset.myWorkspaceTargets = JSON.stringify(["#scenarioWorkspace"]);
    document.body.dataset.myWorkspaceTarget = "#scenarioWorkspace";
    setWorkspaceNavVisible("#operationsWorkspace", false);
    setWorkspaceNavVisible("#procurementWorkspace", false);
    return;
  }

  const roles = new Set((data || []).map(row => row.operational_role));
  const targets = [];
  if (roles.has("warehouse")) targets.push("#inventoryWorkspace", "#procurementWorkspace");
  if (["supplier", "manufacturer"].some(role => roles.has(role))) {
    if (!targets.includes("#procurementWorkspace")) targets.push("#procurementWorkspace");
  }
  if (["customer", "retailer", "transport"].some(role => roles.has(role))) targets.push("#operationsWorkspace");
  if (!targets.length) targets.push("#scenarioWorkspace");
  document.body.dataset.myWorkspaceTargets = JSON.stringify(targets);
  document.body.dataset.myWorkspaceTarget = targets[0];
  setWorkspaceNavVisible("#operationsWorkspace",
    ["customer", "retailer", "transport"].some(role => roles.has(role)));
  setWorkspaceNavVisible("#procurementWorkspace",
    ["supplier", "manufacturer", "warehouse"].some(role => roles.has(role)));
}

async function loadProfile(user) {
  const { data, error } = await supabase.from("profiles")
    .select("full_name, platform_role").eq("id", user.id).single();
  if (error) throw error;
  return data;
}
async function handleSession(session) {
  if (!session?.user) {
    gate.hidden = false;
    return;
  }
  try {
    const profile = await loadProfile(session.user);
    showApp(session.user, profile);
    await syncWorkspaceNavigation(session.user, profile);
  } catch (error) {
    gate.hidden = false;
    showMessage("Could not load your profile. Check that supabase/schema.sql has been run. " + error.message);
  }
}

if (!SUPABASE_URL.startsWith("https://") || SUPABASE_ANON_KEY.startsWith("PASTE_")) {
  gate.hidden = false;
  showMessage("Supabase is not configured yet. Add your Project URL and public anon/publishable key in supabase-config.js.");
  submit.disabled = true;
  switchButton.disabled = true;
} else {
  supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  supabase.auth.onAuthStateChange((_event, session) => {
    // Defer profile query to avoid running Supabase calls inside the auth callback.
    if (session?.user) setTimeout(() => handleSession(session), 0);
    else { gate.hidden = false; }
  });
  supabase.auth.getSession().then(({data}) => handleSession(data.session));
}

switchButton.addEventListener("click", () => setMode(mode === "login" ? "register" : "login"));
form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!supabase) return;
  submit.disabled = true;
  submit.textContent = mode === "register" ? "Creating account…" : "Signing in…";
  showMessage("");
  try {
    const email = emailInput.value.trim();
    const password = passwordInput.value;
    if (mode === "register") {
      const full_name = nameInput.value.trim();
      const {data, error} = await supabase.auth.signUp({
        email, password, options:{data:{full_name}}
      });
      if (error) throw error;
      if (data.session) {
        await handleSession(data.session);
      } else {
        showMessage("Account created. Check your email to confirm the address, then sign in.", true);
        setMode("login");
      }
    } else {
      const {data, error} = await supabase.auth.signInWithPassword({email,password});
      if (error) throw error;
      await handleSession(data.session);
    }
  } catch (error) {
    showMessage(error.message || "Something went wrong. Please try again.");
  } finally {
    submit.disabled = false;
    submit.textContent = mode === "register" ? "Create student account" : "Sign in";
  }
});
document.querySelector("#signOutBtn").addEventListener("click", async () => {
  if (!supabase) return;
  const {error} = await supabase.auth.signOut();
  if (error) showMessage(error.message);
  else { gate.hidden = false; setMode("login"); }
});
