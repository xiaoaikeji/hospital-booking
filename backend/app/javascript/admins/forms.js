// Tabler handles the modal; this binding confirms account disabling and marks real submissions busy.
window.adminForms = {
  setBusy(form, busy) {
    if (busy) form.setAttribute("aria-busy", "true");
    else form.removeAttribute("aria-busy");

    form.querySelectorAll("[data-admin-submit]").forEach((button) => {
      if (busy ? button.disabled : !button.hasAttribute("data-admin-submitting")) return;
      button.toggleAttribute("data-admin-submitting", busy);
      button.disabled = busy;
      button.querySelector("[data-admin-submit-icon]")?.classList.toggle("d-none", busy);
      button.querySelector(".spinner-border").classList.toggle("d-none", !busy);
    });
  }
};

document.addEventListener("submit", (event) => {
  const form = event.target.closest("form[data-admin-form]");
  if (!form || event.defaultPrevented) return;

  if (form.dataset.disableConfirmation && form.dataset.confirmed !== "true" &&
      form.elements.namedItem(form.dataset.disableField || "administrator[enabled]")?.value === (form.dataset.disableValue || "false")) {
    event.preventDefault();
    window.tabler.Modal.getOrCreateInstance(document.getElementById(form.dataset.disableConfirmation)).show();
    return;
  }

  window.adminForms.setBusy(form, true);
});

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-admin-confirm-form]");
  if (!button) return;
  const form = document.getElementById(button.dataset.adminConfirmForm);
  form.dataset.confirmed = "true";
  form.requestSubmit();
});

// Restore controls when a completed form is brought back from the browser's page cache.
window.addEventListener("pageshow", (event) => {
  document.querySelectorAll("form[data-admin-form]").forEach((form) => {
    delete form.dataset.confirmed;
    window.adminForms.setBusy(form, false);
  });
  if (event.persisted) {
    document.querySelectorAll("input[data-write-only]").forEach((input) => { input.value = ""; });
  }
});
