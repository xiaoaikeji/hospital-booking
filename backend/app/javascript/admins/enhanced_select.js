document.addEventListener("DOMContentLoaded", () => {
  if (!window.TomSelect) return;

  document.querySelectorAll("select[data-enhanced-select]").forEach((select) => {
    if (select.tomselect) return;

    const options = { create: false, copyClassesToDropdown: false, dropdownParent: select.closest(".modal-content") || "body" };
    if (select.dataset.enhancedSelect === "single") {
      options.controlInput = null;
      options.allowEmptyOption = true;
    }

    const control = new window.TomSelect(select, options).focus_node;
    ["aria-label", "aria-describedby", "aria-invalid", "aria-required"].forEach((name) => {
      if (select.hasAttribute(name)) control.setAttribute(name, select.getAttribute(name));
    });
  });
});
