document.addEventListener("DOMContentLoaded", () => {
  if (!window.TomSelect) return;

  document.querySelectorAll("select[data-enhanced-select]").forEach((select) => {
    if (select.tomselect) return;

    const options = { create: false, copyClassesToDropdown: false, dropdownParent: "body" };
    if (select.dataset.enhancedSelect === "single") {
      options.controlInput = null;
      options.allowEmptyOption = true;
    }

    new window.TomSelect(select, options);
  });
});
