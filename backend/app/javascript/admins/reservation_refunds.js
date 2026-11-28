(() => {
  document.querySelectorAll("form[data-refund-review]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      if (form.dataset.confirmed !== "true" || form.hasAttribute("aria-busy")) {
        event.preventDefault();
        return;
      }
      form.setAttribute("aria-busy", "true");
    });
    window.addEventListener("pageshow", () => {
      delete form.dataset.confirmed;
      form.removeAttribute("aria-busy");
    });
  });

  const dialog = document.getElementById("confirm-hospital-refund");
  if (!dialog) return;

  const confirm = dialog.querySelector("[data-refund-submit]");
  let draft;
  let submitting = false;

  document.querySelectorAll("form[data-refund-draft]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      if (submitting && draft === form) return;

      event.preventDefault();
      const reason = form.elements.namedItem("refund[reason]");
      if (!reason.value.trim()) {
        reason.value = "";
        reason.reportValidity();
        return;
      }

      draft = form;
      const amount = form.elements.namedItem("refund[amount]");
      const cents = form.elements.namedItem("refund[confirmed_available]").value;
      const freeReturn = form.dataset.refundDraft === "return" && Number(cents) === 0;
      const yuan = (amount ? Number(amount.value) : Number(cents) / 100).toFixed(2);
      dialog.querySelector("#confirm-hospital-refund-title").textContent = form.dataset.refundTitle;
      dialog.querySelector("#confirm-hospital-refund-description").textContent = freeReturn ? "确认后取消预约并释放号源" : form.dataset.refundEffect;
      dialog.querySelector("[data-refund-summary-amount]").textContent = freeReturn ? "" : `本次退款 ${yuan} 元`;
      dialog.querySelector("[data-refund-summary-reason]").textContent = reason.value.trim();
      confirm.textContent = freeReturn ? "确认退号" : `确认退款 ¥${yuan}`;

      const editor = form.closest(".modal");
      editor.addEventListener("hidden.bs.modal", () => {
        window.tabler.Modal.getOrCreateInstance(dialog).show();
      }, { once: true });
      window.tabler.Modal.getOrCreateInstance(editor).hide();
    });
  });

  dialog.querySelector("[data-refund-back]").addEventListener("click", () => {
    dialog.addEventListener("hidden.bs.modal", () => {
      window.tabler.Modal.getOrCreateInstance(draft.closest(".modal")).show();
    }, { once: true });
  });

  confirm.addEventListener("click", () => {
    if (submitting || !draft?.reportValidity()) return;

    submitting = true;
    confirm.disabled = true;
    draft.elements.namedItem("refund[confirmed_available]").disabled = false;
    draft.requestSubmit();
  });

  window.addEventListener("pageshow", () => {
    submitting = false;
    confirm.disabled = false;
    if (draft) draft.elements.namedItem("refund[confirmed_available]").disabled = true;
  });
})();
