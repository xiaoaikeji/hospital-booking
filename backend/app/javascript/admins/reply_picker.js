document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-reply-picker]").forEach(picker => {
    const form = picker.closest("form");
    const mode = form.querySelector("#scan-mode");
    const select = picker.querySelector("[data-reply-choice]");
    const edit = picker.querySelector("[data-reply-edit]");
    const revision = form.querySelector("[data-reply-revision]");
    let popup;

    window.initializeAdminSelects(form);
    function updatePicker() {
      const active = mode.value === "reply" || mode.value === "both";
      picker.classList.toggle("d-none", !active);
      picker.disabled = !active;
      if (select.tomselect) {
        if (active) select.tomselect.enable();
        else select.tomselect.disable();
      } else {
        select.disabled = !active;
      }
      edit.disabled = !active || !select.value;
    }

    mode.addEventListener("change", updatePicker);
    select.addEventListener("change", updatePicker);
    updatePicker();
    picker.querySelector("[data-reply-new]").onclick = () => {
      popup = window.open(picker.dataset.new, "booking-reply-" + picker.dataset.appId, "width=1100,height=850");
    };
    edit.onclick = () => {
      const url = picker.dataset.editBase + "/" + encodeURIComponent(select.value) + "/edit?inline=1" +
        (picker.dataset.codeId ? "&qrcode_id=" + picker.dataset.codeId : "");
      popup = window.open(url, "booking-reply-" + picker.dataset.appId, "width=1100,height=850");
    };
    window.addEventListener("message", event => {
      if (event.origin !== location.origin || event.source !== popup || event.data.type !== "booking.reply.saved" || String(event.data.appId) !== picker.dataset.appId) return;
      const row = event.data;
      if (select.tomselect) {
        select.tomselect.addOption({ value: row.id, text: row.name });
        select.tomselect.updateOption(row.id, { value: row.id, text: row.name });
        select.tomselect.setValue(row.id);
      } else {
        select.add(new Option(row.name, row.id));
        select.value = row.id;
      }
      revision.value = row.revision;
      updatePicker();
    });
  });
});
