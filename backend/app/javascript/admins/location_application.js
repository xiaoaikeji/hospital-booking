document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("location-application");
  if (!form) return;
  const content = form.querySelector("textarea");
  const counter = form.querySelector("[data-location-count]");
  const count = () => { counter.textContent = Array.from(content.value).length; };
  content.addEventListener("input", count);
  form.querySelectorAll("[data-location-example]").forEach(button => {
    button.addEventListener("click", () => {
      content.value = button.dataset.locationExample;
      count();
      content.focus();
    });
  });
  form.addEventListener("submit", event => {
    if (form.dataset.confirmed === "true") {
      delete form.dataset.confirmed;
      form.querySelector("button[type=submit]").disabled = true;
      return;
    }
    event.preventDefault();
    window.tabler.Modal.getOrCreateInstance(document.getElementById("location-apply-confirm")).show();
  });
});
