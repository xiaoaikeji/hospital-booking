// Keep rendering and selection in Tabler, and open popup fields on explicit activation.
const dateInputSelector = "input[data-admin-date-input]";

// Install the calendar's native click handler before the click reaches the input.
document.addEventListener("click", event => {
  const input = event.target.closest(dateInputSelector);
  if (input) window.tabler.Datepicker.getOrCreateInstance(input);
}, true);

document.addEventListener("click", event => {
  const button = event.target.closest("[data-admin-date-clear]");
  if (!button) return;

  const input = document.getElementById(button.dataset.adminDateClear);
  const target = document.getElementById(button.dataset.adminDatePicker);
  if (!input || !target || !window.tabler?.Datepicker) return;

  const picker = window.tabler.Datepicker.getOrCreateInstance(target);
  picker.setSelectedDates([]);
  picker.hide();
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
});

document.addEventListener("keydown", event => {
  if (event.defaultPrevented || event.key !== "ArrowDown" || !event.target.matches(dateInputSelector)) return;

  event.preventDefault();
  event.target.click();
});

document.addEventListener("shown.bs.datepicker", event => {
  const input = event.target;
  if (!input.matches(dateInputSelector)) return;

  input.setAttribute("aria-expanded", "true");
  const modal = input.closest(".modal");
  if (modal) {
    const popup = window.tabler.Datepicker.getInstance(input).calendar.context.mainElement;
    popup.style.setProperty("--tblr-datepicker-zindex", Number(getComputedStyle(modal).zIndex) + 1);
  }
});

document.addEventListener("hidden.bs.datepicker", event => {
  if (event.target.matches(dateInputSelector)) event.target.setAttribute("aria-expanded", "false");
});

document.addEventListener("hide.bs.modal", event => {
  event.target.querySelectorAll(dateInputSelector).forEach(input => window.tabler.Datepicker.getInstance(input)?.hide());
});
