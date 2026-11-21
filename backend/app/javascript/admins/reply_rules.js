document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-rules]");
  if (!root) return;
  const rows = root.querySelector("[data-keyword-rows]");
  const template = root.querySelector("[data-keyword-template]");

  function updatePositions() {
    const rules = [...rows.children];
    rules.forEach((row, index) => {
      const position = index + 1;
      row.querySelector("[data-keyword-position]").textContent = position;
      const up = row.querySelector('[data-move-keyword="up"]');
      const down = row.querySelector('[data-move-keyword="down"]');
      up.setAttribute("aria-label", `上移第 ${position} 条规则`);
      down.setAttribute("aria-label", `下移第 ${position} 条规则`);
      up.disabled = index === 0;
      down.disabled = position === rules.length;
    });
  }

  if (window.Sortable) {
    window.Sortable.create(rows, { handle: "[data-keyword-handle]", animation: 150, onEnd: updatePositions });
  }

  root.querySelector("[data-add-keyword]").onclick = () => {
    const index = Number(rows.dataset.nextIndex);
    const fragment = template.content.cloneNode(true);
    fragment.querySelectorAll("[id]").forEach(control => { control.id = control.id.replace("NEW_INDEX", index); });
    fragment.querySelectorAll("label").forEach(label => { label.htmlFor = label.htmlFor.replace("NEW_INDEX", index); });
    const row = fragment.firstElementChild;
    rows.append(fragment);
    rows.dataset.nextIndex = index + 1;
    window.initializeAdminSelects(row);
    updatePositions();
    row.querySelector("input").focus();
  };

  rows.addEventListener("click", event => {
    const button = event.target.closest("[data-move-keyword], [data-remove-keyword]");
    if (!button) return;
    const row = button.closest("[data-keyword-row]");
    if (button.dataset.moveKeyword) {
      if (button.dataset.moveKeyword === "up") row.previousElementSibling?.before(row);
      else row.nextElementSibling?.after(row);
      updatePositions();
      if (button.disabled) row.querySelector("[data-move-keyword]:not([disabled])")?.focus();
      else button.focus();
      return;
    }
    row.querySelectorAll("select").forEach(select => select.tomselect?.destroy());
    row.remove();
    updatePositions();
  });
  updatePositions();
});
