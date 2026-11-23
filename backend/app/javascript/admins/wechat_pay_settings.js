const form = document.querySelector("form[data-wechat-pay-settings]");
if (form) {
  const version = form.elements.namedItem("wechat_pay[version]");
  const showVersion = () => {
    form.querySelectorAll("[data-payment-version]").forEach((fieldset) => {
      const active = fieldset.dataset.paymentVersion === version.value;
      fieldset.hidden = !active;
      fieldset.disabled = !active;
    });
  };
  version.addEventListener("change", showVersion);
  showVersion();
}
