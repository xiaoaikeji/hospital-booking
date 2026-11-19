// Tabler handles the modal; this binding confirms account disabling and marks real submissions busy.
document.addEventListener("submit", (event) => {
  const form = event.target.closest("form[data-admin-form]");
  if (!form) return;

  if (form.dataset.disableConfirmation && form.dataset.confirmed !== "true" &&
      form.elements.namedItem(form.dataset.disableField || "administrator[enabled]")?.value === (form.dataset.disableValue || "false")) {
    event.preventDefault();
    window.tabler.Modal.getOrCreateInstance(document.getElementById(form.dataset.disableConfirmation)).show();
    return;
  }

  form.setAttribute("aria-busy", "true");
  form.querySelectorAll("[data-admin-submit]").forEach((button) => {
    button.disabled = true;
    button.querySelector("[data-admin-submit-icon]")?.classList.add("d-none");
    button.querySelector(".spinner-border").classList.remove("d-none");
  });
});

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-admin-confirm-form]");
  if (!button) return;
  const form = document.getElementById(button.dataset.adminConfirmForm);
  form.dataset.confirmed = "true";
  form.requestSubmit();
});

// Restore controls when a completed form is brought back from the browser's page cache.
window.addEventListener("pageshow", () => {
  document.querySelectorAll("form[data-admin-form]").forEach((form) => {
    form.removeAttribute("aria-busy");
    delete form.dataset.confirmed;
    form.querySelectorAll("[data-admin-submit]").forEach((button) => {
      button.disabled = false;
      button.querySelector("[data-admin-submit-icon]")?.classList.remove("d-none");
      button.querySelector(".spinner-border").classList.add("d-none");
    });
  });
});
