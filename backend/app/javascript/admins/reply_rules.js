document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-rules]");
  if (!root) return;
  const rows = root.querySelector("[data-keyword-rows]");
  const template = root.querySelector("[data-keyword-template]");

  root.querySelector("[data-add-keyword]").onclick = () => {
    const index = Number(rows.dataset.nextIndex);
    const fragment = template.content.cloneNode(true);
    fragment.querySelectorAll("[id]").forEach(control => { control.id = control.id.replace("NEW_INDEX", index); });
    fragment.querySelectorAll("label").forEach(label => { label.htmlFor = label.htmlFor.replace("NEW_INDEX", index); });
    const row = fragment.firstElementChild;
    rows.append(fragment);
    rows.dataset.nextIndex = index + 1;
    window.initializeAdminSelects(row);
    row.querySelector("input").focus();
  };

  rows.addEventListener("click", event => {
    const button = event.target.closest("[data-remove-keyword]");
    if (!button) return;
    const row = button.closest("[data-keyword-row]");
    row.querySelectorAll("select").forEach(select => select.tomselect?.destroy());
    row.remove();
  });
});
