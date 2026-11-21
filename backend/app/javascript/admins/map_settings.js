const form = document.querySelector("form[data-map-settings]");
if (form) {
  const provider = form.elements.namedItem("map[provider]");
  const showCredential = () => {
    form.querySelectorAll("[data-map-credential]").forEach((fieldset) => {
      const active = fieldset.dataset.mapCredential === provider.value;
      fieldset.hidden = !active;
      fieldset.disabled = !active;
    });
  };
  provider.addEventListener("change", showCredential);
  showCredential();
}
