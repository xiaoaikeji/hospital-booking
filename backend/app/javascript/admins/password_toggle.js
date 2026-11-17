// From Tabler 1.7.1 dashboard/sign-in.html, BEGIN INPUT GROUP PASSWORD TOGGLE; labels translated to Chinese.
if (!window.__tablerPasswordToggleInit) {
  window.__tablerPasswordToggleInit = true;
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-password-toggle]");
    if (!button) return;
    const input = document.getElementById(button.getAttribute("data-password-toggle"));
    if (!input) return;
    const showing = input.type === "password";
    input.type = showing ? "text" : "password";
    const label = showing ? "隐藏密码" : "显示密码";
    button.setAttribute("aria-pressed", showing ? "true" : "false");
    button.setAttribute("aria-label", label);
    button.setAttribute("title", label);
    button.setAttribute("data-bs-original-title", label);
    button.querySelector(".icon-toggle-show")?.classList.toggle("d-none", showing);
    button.querySelector(".icon-toggle-hide")?.classList.toggle("d-none", !showing);
  });
}
