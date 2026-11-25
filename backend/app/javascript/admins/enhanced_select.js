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

    const widget = new window.TomSelect(select, options);
    const control = widget.focus_node;
    ["aria-label", "aria-describedby", "aria-invalid", "aria-required"].forEach((name) => {
      if (select.hasAttribute(name)) control.setAttribute(name, select.getAttribute(name));
    });

    if (options.controlInput === null && widget.settings.placeholder) {
      // The non-searchable control has no input to display its placeholder.
      const placeholder = document.createElement("span");
      placeholder.className = "text-secondary";
      placeholder.textContent = widget.settings.placeholder;
      placeholder.setAttribute("aria-hidden", "true");
      widget.control.append(placeholder);

      const updatePlaceholder = () => placeholder.classList.toggle("d-none", widget.items.length > 0);
      widget.on("item_add", updatePlaceholder);
      widget.on("item_remove", updatePlaceholder);
      updatePlaceholder();
    }
  });
};

document.addEventListener("DOMContentLoaded", () => window.initializeAdminSelects());
