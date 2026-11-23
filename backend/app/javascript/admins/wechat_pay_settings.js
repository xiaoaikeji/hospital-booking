const form = document.querySelector("form[data-wechat-pay-settings]");
if (form) {
  const version = form.elements.namedItem("wechat_pay[version]");
  const fields = form.querySelector("[data-payment-fields]");
  const showVersion = () => {
    fields.classList.toggle("row-cols-xl-4", version.value === "v2");
    fields.classList.toggle("row-cols-xl-3", version.value !== "v2");
    form.querySelectorAll("[data-payment-version]").forEach((fieldset) => {
      const active = fieldset.dataset.paymentVersion === version.value;
      fieldset.hidden = !active;
      fieldset.disabled = !active;
    });
  };
  version.addEventListener("change", showVersion);
  showVersion();
}
