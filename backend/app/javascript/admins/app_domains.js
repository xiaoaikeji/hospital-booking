document.querySelectorAll("[data-domain-editor]").forEach(editor => {
  function fill(button) {
    const field = document.getElementById(button.dataset.fillDomain);
    field.value = button.dataset.value;
    const clear = field.parentElement.querySelector('input[type="checkbox"]');
    if (clear) clear.checked = false;
  }

  editor.addEventListener("click", event => {
    const button = event.target.closest("[data-fill-domain]");
    if (button) fill(button);
    if (event.target.closest("[data-all-domain-defaults]")) editor.querySelectorAll("[data-fill-domain]").forEach(fill);
  });
});
