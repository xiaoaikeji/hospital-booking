const slotSwitch = document.getElementById("appointment_booking_by_time_slot");
const defaultCapacity = document.getElementById("appointment-default-capacity");
const slotCapacity = document.getElementById("appointment-slot-capacity");

function setCapacityActive(group, active) {
  group.classList.toggle("d-none", !active);
  group.querySelector("input").disabled = !active;
}

function updateCapacityFields() {
  setCapacityActive(defaultCapacity, !slotSwitch.checked);
  setCapacityActive(slotCapacity, slotSwitch.checked);
}

slotSwitch.addEventListener("change", updateCapacityFields);
window.addEventListener("pageshow", updateCapacityFields);
