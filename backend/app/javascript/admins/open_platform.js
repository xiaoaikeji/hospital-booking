document.addEventListener("submit", (event) => {
  const form = event.target.closest("form[data-open-platform-confirm]");
  if (!form) return;
  if (form.dataset.confirmed === "true") {
    delete form.dataset.confirmed;
    return;
  }
  event.preventDefault();
  const modal = document.getElementById(form.dataset.openPlatformConfirm);
  const description = modal.querySelector("[id$='-description']");
  description.dataset.explanation ||= description.textContent;
  const selected = form.elements.namedItem("app_id").selectedOptions[0];
  description.textContent = selected.text + "。" + description.dataset.explanation;
  window.tabler.Modal.getOrCreateInstance(modal).show();
});
