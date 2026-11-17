// Thin application binding: keep rendering and selection in Tabler's official Datepicker.
document.addEventListener("click", (event) => {
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
