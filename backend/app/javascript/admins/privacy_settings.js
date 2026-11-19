document.addEventListener("click", event => {
  const button = event.target.closest("[data-add-privacy-entry]");
  if (!button) return;
  const index = Number(button.dataset.next);
  const row = document.getElementById("privacy-entry-template").content.cloneNode(true);
  row.querySelectorAll("[name], [for], [id]").forEach(element => {
    for (const attribute of ["name", "for", "id"]) {
      if (element.hasAttribute(attribute)) element.setAttribute(attribute, element.getAttribute(attribute).replace("NEW_ENTRY", index));
    }
  });
  button.dataset.next = index + 1;
  document.getElementById("privacy-entries").append(row);
  document.getElementById("privacy-key-" + index).focus();
});
