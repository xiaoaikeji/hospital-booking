window.initializeAdminSelects = (root = document) => {
  if (!window.TomSelect) return;

  root.querySelectorAll("select[data-enhanced-select]").forEach((select) => {
    if (select.tomselect) return;

    const options = { create: false, copyClassesToDropdown: false, dropdownParent: select.hasAttribute("data-inline-dropdown") ? null : (select.closest(".modal-content") || "body") };
    if (select.dataset.enhancedSelect === "single") {
      options.controlInput = null;
      options.allowEmptyOption = !select.required && Array.from(select.options).some(
        (option) => option.value === "" && option.label.trim() !== ""
      );
    }

    const control = new window.TomSelect(select, options).focus_node;
    ["aria-label", "aria-describedby", "aria-invalid", "aria-required"].forEach((name) => {
      if (select.hasAttribute(name)) control.setAttribute(name, select.getAttribute(name));
    });
  });
};

document.addEventListener("DOMContentLoaded", () => window.initializeAdminSelects());
