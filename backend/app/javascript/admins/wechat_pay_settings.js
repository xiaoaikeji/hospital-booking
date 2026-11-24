const form = document.querySelector("form[data-wechat-pay-settings]");
if (form) {
  const version = form.elements.namedItem("wechat_pay[version]");
  const merchant = form.elements.namedItem("wechat_pay[merchant_id]");
  const fields = form.querySelector("[data-payment-fields]");
  const notice = form.querySelector("[data-merchant-change]");
  const backup = form.querySelector("[data-remove-backup]");
  const backupInputs = [...form.querySelectorAll('[name^="wechat_pay[backup_verification_"]')];
  const configuredMerchant = form.dataset.configuredMerchant;
  const currentMerchant = () => merchant.value.trim() || configuredMerchant;
  const initialMerchant = currentMerchant();
  const originalForm = !configuredMerchant || initialMerchant === configuredMerchant;
  let lastMerchant = initialMerchant;

  const credentials = [...form.querySelectorAll("[data-merchant-credential]")].map((group) => {
    const input = group.querySelector("input, textarea");
    const label = group.querySelector("label");
    const badge = group.querySelector(".badge");
    return { input, label, badge, placeholder: input.placeholder, requirement: group.dataset.credentialRequirement };
  });
  const changingMerchant = () => Boolean(configuredMerchant) && currentMerchant() !== configuredMerchant;
  const showBackup = () => {
    const saved = !changingMerchant() && initialMerchant === configuredMerchant && backupInputs.some((input) => input.defaultValue.trim());
    backup.hidden = !saved && !backupInputs.some((input) => input.value.trim()) && !backup.querySelector("input[type=checkbox]").checked;
  };
  const showFields = () => {
    const changing = changingMerchant();
    notice.hidden = !changing;
    notice.querySelectorAll("[data-merchant-version]").forEach((text) => {
      text.hidden = text.dataset.merchantVersion !== version.value;
    });
    fields.classList.toggle("row-cols-xl-4", version.value === "v2");
    fields.classList.toggle("row-cols-xl-3", version.value !== "v2");
    form.querySelectorAll("[data-payment-version]").forEach((fieldset) => {
      const active = fieldset.dataset.paymentVersion === version.value && !(changing && fieldset.hasAttribute("data-original-merchant"));
      fieldset.hidden = !active;
      fieldset.disabled = !active;
    });
    credentials.forEach(({ input, label, badge, placeholder, requirement }) => {
      const required = requirement === "always" || (changing && requirement === "new-merchant");
      label.classList.toggle("required", required);
      input.required = required;
      if (badge) badge.hidden = changing || !originalForm;
      input.placeholder = changing || !originalForm ? "" : placeholder;
    });
    showBackup();
  };
  const changeMerchant = () => {
    const owner = currentMerchant();
    if (configuredMerchant && owner !== lastMerchant) {
      credentials.forEach(({ input }) => {
        input.value = owner === configuredMerchant && initialMerchant === configuredMerchant ? input.defaultValue : "";
      });
      form.querySelectorAll("input[type=checkbox]").forEach((input) => { input.checked = false; });
    }
    lastMerchant = owner;
    showFields();
  };
  merchant.addEventListener("input", changeMerchant);
  merchant.addEventListener("change", changeMerchant);
  version.addEventListener("change", showFields);
  backupInputs.forEach((input) => input.addEventListener("input", showBackup));
  showFields();
}
