document.querySelectorAll("[data-schedule-capacity]").forEach((shift) => {
  const capacity = document.getElementById(shift.dataset.scheduleCapacity);
  const updateCapacity = () => {
    const enabled = shift.type === "checkbox" ? shift.checked : shift.value !== "";
    capacity.disabled = shift.disabled || !enabled;
  };

  shift.addEventListener("change", updateCapacity);
  updateCapacity();
});

const dateLookup = document.querySelector("form[data-date-editor]");
if (dateLookup) {
  const input = dateLookup.elements.namedItem("date");
  const feedback = document.getElementById(`${input.id}-error`);
  const editor = document.getElementById(dateLookup.dataset.dateEditor);
  const loadedDate = editor.elements.namedItem("date").value;
  const actions = editor.querySelectorAll(".card-footer button");

  const updateDate = (showError) => {
    const date = new Date(`${input.value}T00:00:00Z`);
    const valid = /^(?!0000)\d{4}-\d{2}-\d{2}$/.test(input.value) &&
      Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === input.value;
    const invalid = !valid && (showError || input.classList.contains("is-invalid"));
    input.classList.toggle("is-invalid", invalid);
    feedback.classList.toggle("d-block", invalid);
    if (invalid) {
      input.setAttribute("aria-invalid", "true");
      input.setAttribute("aria-describedby", feedback.id);
    } else {
      input.removeAttribute("aria-invalid");
      input.removeAttribute("aria-describedby");
    }
    actions.forEach((button) => {
      button.disabled = !valid || input.value !== loadedDate || button.hasAttribute("data-admin-submitting");
    });
    return valid;
  };

  dateLookup.noValidate = true;
  dateLookup.addEventListener("submit", (event) => {
    if (updateDate(true)) return;
    event.preventDefault();
    input.focus();
  });
  editor.addEventListener("submit", (event) => {
    if (input.value !== loadedDate) event.preventDefault();
  });
  input.addEventListener("input", () => updateDate(false));
  const loadDate = () => {
    if (updateDate(true) && input.value !== input.defaultValue) dateLookup.requestSubmit();
  };
  input.addEventListener("change", loadDate);
  input.addEventListener("change.bs.datepicker", loadDate);
  updateDate(false);
}
