document.addEventListener("DOMContentLoaded", () => {
  const scope = document.querySelector("[data-page-link-scope]");
  scope?.addEventListener("change", () => scope.form.requestSubmit());

  const form = document.querySelector("[data-page-link-form]");
  if (!form) return;

  const type = form.querySelector("[data-page-link-type]");
  function updateDestinations() {
    form.querySelectorAll("[data-page-link-fields]").forEach((group) => {
      const active = group.dataset.pageLinkFields === type.value;
      group.hidden = !active;
      group.querySelectorAll("input, select").forEach((field) => {
        field.disabled = !active;
        if (field.tomselect) {
          if (active) field.tomselect.enable();
          else field.tomselect.disable();
        }
      });
    });
  }
  type.addEventListener("change", updateDestinations);
  updateDestinations();
});
