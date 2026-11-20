document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-reply-picker]").forEach(root => {
    const mode = document.getElementById("scan-mode"); if (mode && window.TomSelect) new window.TomSelect(mode, { create: false, controlInput: null, dropdownParent: "body" });
    const select = root.querySelector("[data-reply-choice]"); let popup;
    if (window.TomSelect) new window.TomSelect(select, { create: false, controlInput: null, allowEmptyOption: true, dropdownParent: "body" });
    root.querySelector("[data-reply-new]").onclick = () => { popup = window.open(root.dataset.new, "booking-reply-" + root.dataset.appId, "width=1100,height=850"); };
    root.querySelector("[data-reply-edit]").onclick = () => {
      if (!select.value) return;
      const url = root.dataset.editBase + "/" + encodeURIComponent(select.value) + "/edit?inline=1" + (root.dataset.codeId ? "&qrcode_id=" + root.dataset.codeId : "");
      popup = window.open(url, "booking-reply-" + root.dataset.appId, "width=1100,height=850");
    };
    window.addEventListener("message", event => {
      if (event.origin !== location.origin || event.source !== popup || event.data.type !== "booking.reply.saved" || String(event.data.appId) !== root.dataset.appId) return;
      const row = event.data;
      if (select.tomselect) { select.tomselect.addOption({ value: row.id, text: row.name }); select.tomselect.updateOption(row.id, { value: row.id, text: row.name }); select.tomselect.setValue(row.id); }
      else { select.add(new Option(row.name, row.id)); select.value = row.id; }
      root.querySelector("[data-reply-revision]").value = row.revision;
    });
  });
});
