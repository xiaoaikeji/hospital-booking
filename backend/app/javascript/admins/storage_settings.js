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
