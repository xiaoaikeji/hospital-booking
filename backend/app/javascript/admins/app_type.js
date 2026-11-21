document.addEventListener("DOMContentLoaded", () => {
  const platform = document.querySelector("#app_provider");
  const type = document.querySelector("#app_app_type");
  if (!platform || !type || platform.disabled) return;

  function updateTypes() {
    const restricted = platform.value === "douyin";
    if (restricted && type.value === "official_account") {
      if (type.tomselect) type.tomselect.setValue("mini_program");
      else type.value = "mini_program";
    }
    const callback = document.getElementById("official-account-callback");
    if (callback) callback.hidden = callback.disabled = restricted || type.value !== "official_account";
    const option = type.querySelector('option[value="official_account"]');
    if (option) option.disabled = restricted;
    const control = type.tomselect;
    if (control && control.options.official_account) {
      control.updateOption("official_account", { ...control.options.official_account, disabled: restricted });
      control.refreshOptions(false);
    }
  }

  platform.addEventListener("change", updateTypes);
  type.addEventListener("change", updateTypes);
  updateTypes();
});
