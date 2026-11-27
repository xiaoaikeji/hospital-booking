document.querySelectorAll("[data-schedule-capacity]").forEach((shift) => {
  const capacity = document.getElementById(shift.dataset.scheduleCapacity);
  const limits = JSON.parse(capacity.dataset.slotLimits || "null");
  const hint = document.getElementById(`${capacity.id}-hint`);
  const updateCapacity = () => {
    const code = shift.type === "checkbox" ? (shift.checked ? "NIGHT" : "") : shift.value;
    capacity.disabled = shift.disabled || !code;
    capacity.placeholder = code && !limits ? capacity.dataset.defaultCapacityHint : "";
    if (!hint) return;

    const limit = limits[code];
    const warning = Boolean(limit && Number(capacity.value) > limit);
    hint.textContent = warning ? `按当前时段最多可约 ${limit} 人` :
      limit && capacity.value === "" && !capacity.validity.badInput ? `按时段自动计算，共 ${limit} 号` : "";
    hint.classList.toggle("text-warning", warning);
    hint.hidden = !hint.textContent;
  };

  shift.addEventListener("change", updateCapacity);
  capacity.addEventListener("input", updateCapacity);
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
