document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-rules]"); if (!root) return;
  const rows = root.querySelector("[data-keyword-rows]");
  const enhance = (scope) => scope.querySelectorAll("select").forEach(select => { if (window.TomSelect && !select.tomselect) new window.TomSelect(select, { create: false, controlInput: null, dropdownParent: "body" }); });
  root.querySelector("[data-add-keyword]").onclick = () => { rows.append(root.querySelector("template").content.cloneNode(true)); enhance(rows); };
  root.addEventListener("click", event => { if (event.target.matches("[data-remove-keyword]")) event.target.closest("[data-keyword-row]").remove(); }); enhance(root);
});
