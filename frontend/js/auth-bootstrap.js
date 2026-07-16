import { initTopbarWalletProfile } from "./ui.js?v=20260706mobileauth";

function ensureAuthUi() {
  const header = document.querySelector(".topbar, .rwa-topbar, .airi-live-header");
  if (!header) return;
  let actions = header.querySelector(".top-actions");
  if (!actions) {
    actions = document.createElement("div");
    actions.className = "top-actions shared-auth-actions";
    header.appendChild(actions);
  }
  let signInBtn = document.getElementById("signInBtn");
  if (!signInBtn) {
    signInBtn = document.createElement("button");
    signInBtn.id = "signInBtn";
    signInBtn.className = "btn-primary top-action-btn sign-in-btn";
    signInBtn.type = "button";
    signInBtn.textContent = "Sign in";
    actions.prepend(signInBtn);
  } else {
    signInBtn.textContent = "Sign in";
  }
  const ensureHidden = (tag, id) => {
    let node = document.getElementById(id);
    if (node) return node;
    node = document.createElement(tag);
    node.id = id;
    node.hidden = true;
    node.setAttribute("aria-hidden", "true");
    actions.appendChild(node);
    return node;
  };
  const walletSelect = ensureHidden("select", "walletChoice");
  const connectBtn = ensureHidden("button", "connectBtn");
  const disconnectBtn = ensureHidden("button", "disconnectBtn");
  const walletLabel = ensureHidden("span", "walletAddress");
  let alertEl = document.getElementById("alert");
  if (!alertEl) {
    alertEl = document.createElement("div");
    alertEl.id = "alert";
    alertEl.className = "alert";
    alertEl.setAttribute("role", "status");
    document.body.appendChild(alertEl);
  }
  window.pumprTopbarAuth = initTopbarWalletProfile({ signInBtn, connectBtn, disconnectBtn, walletSelect, walletLabel, alertEl });
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ensureAuthUi, { once: true });
else ensureAuthUi();
