// Storage-specific binding; controls and layout keep using the existing Tabler components.
const updateStorageFields = (container) => {
  const enabled = container.querySelector("[data-storage-service] select")?.value === "tencent_cos";
  container.querySelectorAll("[data-storage-cos-fields]").forEach((fieldset) => {
    fieldset.hidden = !enabled;
    fieldset.disabled = !enabled;
  });
};

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-storage-settings]").forEach(updateStorageFields);
});

document.addEventListener("change", (event) => {
  const container = event.target.closest("[data-storage-settings]");
  if (container && event.target.matches("[data-storage-service] select")) updateStorageFields(container);
});

window.addEventListener("pageshow", (event) => {
  if (!event.persisted && performance.getEntriesByType("navigation")[0]?.type !== "back_forward") return;

  document.querySelectorAll("form[data-storage-settings]").forEach((form) => {
    const endpoint = form.elements.namedItem("storage_settings[endpoint]");
    const visibility = form.elements.namedItem("storage_settings[endpoint_visibility]");
    endpoint.value = endpoint.defaultValue;
    visibility.value = "";
  });
});
