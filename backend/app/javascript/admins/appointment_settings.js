const slotSwitch = document.getElementById("appointment_booking_by_time_slot");
const slotCapacity = document.getElementById(slotSwitch.getAttribute("aria-controls"));
const slotInput = slotCapacity.querySelector("input");

function updateSlotCapacity() {
  slotCapacity.classList.toggle("d-none", !slotSwitch.checked);
  slotInput.disabled = !slotSwitch.checked;
}

slotSwitch.addEventListener("change", updateSlotCapacity);
window.addEventListener("pageshow", updateSlotCapacity);
