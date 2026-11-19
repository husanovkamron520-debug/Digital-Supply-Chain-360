import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./supabase-config.js";

const gate = document.querySelector("#authGate");
const form = document.querySelector("#authForm");
const title = document.querySelector("#authTitle");
const subtitle = document.querySelector("#authSubtitle");
const nameInput = document.querySelector("#authName");
const nameLabel = document.querySelector("#authNameLabel");
const emailInput = document.querySelector("#authEmail");
const emailLabel = document.querySelector('label[for="authEmail"]');
const passwordInput = document.querySelector("#authParol");
const magicLinkButton = document.querySelector("#authMagicLink");
const telegramConfirmPanel = document.querySelector("#telegramRegistrationConfirm");
const telegramConfirmButton = document.querySelector("#telegramRegistrationConfirmButton");
const telegramRegistrationToken = new URLSearchParams(window.location.search).get("tg_reg");
if (telegramRegistrationToken) window.history.replaceState({}, document.title, window.location.pathname);
const telegramRecoveryToken = new URLSearchParams(window.location.search).get("tg_reset");
if (telegramRegistrationToken || telegramRecoveryToken) window.history.replaceState({}, document.title, window.location.pathname);
const telegramRecoveryForm = document.querySelector("#telegramPasswordRecovery");
const telegramRecoveryPassword = document.querySelector("#telegramRecoveryPassword");
const telegramRecoveryConfirmPassword = document.querySelector("#telegramRecoveryConfirmPassword");
const telegramRecoverySubmit = document.querySelector("#telegramRecoverySubmit");
let telegramRecoveryBusy = false;
let telegramRecoveryCompleted = false;
let telegramRegistrationCompleted = false;
let telegramConfirmationBusy = false;
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
    ? (telegramRegistrationToken
      ? "Create your account with Telegram. No email address is needed."
      : "Register as a student, then join your classroom with its code.")
    : "Sign in to enter your classroom workspace.";
  nameInput.hidden = !registering;
  nameLabel.hidden = !registering;
  nameInput.required = registering;
  const telegramNewAccount = Boolean(telegramRegistrationToken) && registering;
  if (emailInput) {
    emailInput.hidden = telegramNewAccount;
    emailInput.required = !telegramNewAccount;
  }
  if (emailLabel) emailLabel.hidden = telegramNewAccount;
  passwordInput.autocomplete = registering ? "new-password" : "current-password";
  submit.textContent = registering
    ? (telegramRegistrationToken ? "Create Telegram account" : "Create student account")
    : "Sign in";
  if (magicLinkButton) magicLinkButton.hidden = registering || Boolean(telegramRegistrationToken);
  switchText.textContent = registering ? "Already have an account?" : "New to the platform?";
  switchButton.textContent = registering ? "Sign in" : "Create student account";
  showMessage("");
}
function showApp(user, profile) {
  const fullName = profile?.full_name || user.user_metadata?.full_name || user.email?.split("@")[0] || "User";
  const role = profile?.platform_role || "student";
  gate.hidden = true;
  if (telegramConfirmPanel) telegramConfirmPanel.hidden = true;
  appShell?.classList.remove("auth-locked");
  document.querySelector("#userRole").textContent = role.toUpperCase();
  document.querySelector("#userAvatar").textContent = fullName.trim().charAt(0).toUpperCase();
  document.querySelector("#sidebarUserName").textContent = fullName;
  document.querySelector("#sidebarUserRole").textContent = role === "teacher" ? "Teacher workspace" : "Student workspace";
  const todayLabel = document.querySelector("#todayLabel");
  if (todayLabel) todayLabel.textContent = new Intl.DateTimeFormat("en", {weekday:"long", day:"numeric", month:"long", year:"numeric"}).format(new Date()).toUpperCase();
  document.body.dataset.platformRole = role;
}
function setWorkspaceNavVisible(href, visible) {
  document.querySelectorAll(`.nav-link[href="${href}"]`).forEach(link => {
    link.hidden = !visible;
  });
}

async function syncWorkspaceNavigation(user, profile) {
  // This release is intentionally focused on classroom cases and team competitions.
  // Standalone inventory, operations, procurement, analytics and scenario workspaces
  // remain in the repository for possible later restoration, but are not exposed.
  const targets = ["#competitionWorkspace"];
  document.body.dataset.myWorkspaceTargets = JSON.stringify(targets);
  document.body.dataset.myWorkspaceTarget = "#competitionWorkspace";
  setWorkspaceNavVisible("#competitionWorkspace", true);
  for (const href of [
    "#operationsWorkspace",
    "#inventoryWorkspace",
    "#teacherTahlillar",
    "#procurementWorkspace",
    "#scenarioWorkspace"
  ]) {
    setWorkspaceNavVisible(href, false);
  }
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
  if (telegramRecoveryToken && !telegramRecoveryCompleted) {
    gate.hidden = false;
    appShell?.classList.add("auth-locked");
    form.hidden = true;
    document.querySelector(".auth-switch").hidden = true;
    if (magicLinkButton) magicLinkButton.hidden = true;
    if (telegramRecoveryForm) telegramRecoveryForm.hidden = false;
    return;
  }
  if (telegramRegistrationToken && !telegramRegistrationCompleted) {
    gate.hidden = false;
    appShell?.classList.add("auth-locked");
    form.hidden = true;
    document.querySelector(".auth-switch").hidden = true;
    if (magicLinkButton) magicLinkButton.hidden = true;
    if (telegramConfirmPanel) telegramConfirmPanel.hidden = false;
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
if (telegramRegistrationToken) setMode("register");
if (telegramRecoveryToken) {
  form.hidden = true;
  document.querySelector(".auth-switch").hidden = true;
  if (magicLinkButton) magicLinkButton.hidden = true;
  if (telegramRecoveryForm) telegramRecoveryForm.hidden = false;
  showMessage("");
}

if (magicLinkButton) {
  magicLinkButton.addEventListener("click", async () => {
    if (!supabase) return;
    const email = emailInput.value.trim();
    if (!email) {
      showMessage("Avval email manzilingizni kiriting.");
      emailInput.focus();
      return;
    }
    magicLinkButton.disabled = true;
    try {
      const {error} = await supabase.auth.signInWithOtp({
        email,
        options: {
          shouldCreateUser: false,
          emailRedirectTo: "https://digital-supply-chain-360.husanovkamron520.workers.dev/"
        }
      });
      if (error) throw error;
      showMessage("Kirish havolasi emailingizga yuborildi. Inbox yoki Spam papkasini tekshiring.", true);
    } catch (error) {
      showMessage(error.message || "Email havolasini yuborib bo‘lmadi.");
    } finally {
      magicLinkButton.disabled = false;
    }
  });
}

if (telegramConfirmButton) {
  telegramConfirmButton.addEventListener("click", async () => {
    if (!supabase || !telegramRegistrationToken || telegramConfirmationBusy) return;
    telegramConfirmationBusy = true;
    telegramConfirmButton.disabled = true;
    try {
      const {data: sessionData, error: sessionError} = await supabase.auth.getSession();
      if (sessionError) throw sessionError;
      if (!sessionData.session?.user) throw new Error("Email havolasi orqali qayta kiring.");
      const {error} = await supabase.rpc("complete_telegram_registration", {
        p_token: telegramRegistrationToken
      });
      if (error) throw error;
      telegramRegistrationCompleted = true;
      window.history.replaceState({}, document.title, window.location.pathname);
      await handleSession(sessionData.session);
    } catch (error) {
      showMessage(error.message || "Telegram akkauntini ulash amalga oshmadi.");
    } finally {
      telegramConfirmationBusy = false;
      telegramConfirmButton.disabled = false;
    }
  });
}
if (telegramRecoveryForm) {
  telegramRecoveryForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!supabase || !telegramRecoveryToken || telegramRecoveryBusy) return;
    const newPassword = telegramRecoveryPassword.value;
    if (newPassword.length < 8 || newPassword.length > 128) {
      showMessage("Parol 8–128 belgidan iborat bo'lishi kerak.");
      return;
    }
    if (newPassword !== telegramRecoveryConfirmPassword.value) {
      showMessage("Parollar bir-biriga mos kelmadi.");
      telegramRecoveryConfirmPassword.focus();
      return;
    }
    telegramRecoveryBusy = true;
    telegramRecoverySubmit.disabled = true;
    telegramRecoverySubmit.textContent = "Parol yangilanmoqda…";
    try {
      const response = await fetch(`${SUPABASE_URL}/functions/v1/telegram-password-recovery`, {
        method: "POST",
        headers: { "apikey": SUPABASE_ANON_KEY, "Content-Type": "application/json" },
        body: JSON.stringify({ token: telegramRecoveryToken, password: newPassword })
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok || !result.success || !result.telegram_user_id) {
        throw new Error(result.error || "Parolni tiklash amalga oshmadi. Telegram botdan yangi havola oling.");
      }
      telegramRecoveryCompleted = true;
      if (telegramRecoveryForm) telegramRecoveryForm.hidden = true;
      const internalEmail = `tg_${result.telegram_user_id}@telegram.invalid`;
      const {data: loginData, error: loginError} = await supabase.auth.signInWithPassword({
        email: internalEmail, password: newPassword
      });
      if (loginError) {
        emailInput.value = internalEmail;
        passwordInput.value = "";
        telegramRecoveryForm.hidden = true;
        form.hidden = false;
        switchButton.parentElement.hidden = true;
        setMode("login");
        showMessage("Parol muvaffaqiyatli yangilandi. Endi yangi parol bilan tizimga kiring.", true);
        passwordInput.focus();
        return;
      }
      await handleSession(loginData.session);
    } catch (error) {
      showMessage(error.message || "Parolni tiklash xizmati vaqtincha ishlamayapti.");
    } finally {
      telegramRecoveryBusy = false;
      telegramRecoverySubmit.disabled = false;
      telegramRecoverySubmit.textContent = "Parolni yangilash";
    }
  });
}

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
      let signupEmail = email;
      if (telegramRegistrationToken) {
        if (!/^[a-fA-F0-9]{64}$/.test(telegramRegistrationToken)) {
          throw new Error("Telegram ro'yxatdan o'tish havolasi noto'g'ri. Botdan yangi havola oling.");
        }
        const {data: telegramUserId, error: identityError} = await supabase.rpc(
          "get_telegram_registration_user_id",
          {p_token: telegramRegistrationToken}
        );
        if (identityError) throw identityError;
        if (!/^[1-9]\d{4,19}$/.test(String(telegramUserId || ""))) {
          throw new Error("Telegram ro'yxatdan o'tish ma'lumoti topilmadi. Botdan yangi havola oling.");
        }
        // Supabase Auth requires an email-shaped identifier for password auth.
        // This reserved .invalid address is internal only and is never used for delivery.
        signupEmail = `tg_${telegramUserId}@telegram.invalid`;
      }
      const {data, error} = await supabase.auth.signUp({
        email: signupEmail, password, options:{
          data:{full_name},
          ...(telegramRegistrationToken ? {} : {
            emailRedirectTo: "https://digital-supply-chain-360.husanovkamron520.workers.dev/"
          })
        }
      });
      if (error) throw error;
      if (data.session) {
        await handleSession(data.session);
      } else if (telegramRegistrationToken) {
        showMessage("Hisob yaratilmadi: Supabase Auth email tasdiqlashni talab qildi. Dashboard → Authentication → Sign In / Providers → Email bo'limida Confirm email ni o'chiring, so'ng botdan yangi havola oling.");
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
    submit.textContent = mode === "register"
      ? (telegramRegistrationToken ? "Create Telegram account" : "Create student account")
      : "Sign in";
  }
});
document.querySelector("#signOutBtn").addEventListener("click", async () => {
  if (!supabase) return;
  const {error} = await supabase.auth.signOut();
  if (error) showMessage(error.message);
  else { gate.hidden = false; setMode("login"); }
});
