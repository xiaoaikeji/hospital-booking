document.querySelectorAll("[data-single-image-field]").forEach((field) => {
  const file = field.querySelector("input[type=file]");
  const preview = field.querySelector("[data-image-preview]");
  const saved = field.querySelector("[data-image-saved]");
  const selected = field.querySelector("[data-image-selected]");
  const thumbnail = selected.querySelector("img");
  const button = field.querySelector("[data-image-remove]");
  const removal = field.querySelector("[data-image-remove-value]");
  let previewUrl;

  function render() {
    const removing = removal?.value === "1";
    selected.classList.toggle("d-none", !previewUrl);
    saved?.classList.toggle("d-none", Boolean(previewUrl));
    preview.classList.toggle("d-none", !saved && !previewUrl);
    preview.classList.toggle("opacity-50", removing);
    button.classList.toggle("d-none", !removal && !file.files.length);
    button.classList.toggle("btn-outline-danger", !removing);
    button.querySelector("[data-image-trash]").classList.toggle("d-none", removing);
    button.querySelector("[data-image-undo]").classList.toggle("d-none", !removing);
    button.querySelector("[data-image-action-label]").textContent = removing ? "撤销移除" : "移除";
  }

  function clearPreview() {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = undefined;
    thumbnail.removeAttribute("src");
  }

  file.addEventListener("change", () => {
    clearPreview();
    const image = file.files[0];
    if (image) {
      if (removal) removal.value = "0";
      if (image.type.startsWith("image/")) {
        previewUrl = URL.createObjectURL(image);
        thumbnail.src = previewUrl;
      }
    }
    render();
  });

  button.addEventListener("click", () => {
    if (file.files.length) {
      file.value = "";
      clearPreview();
    } else if (removal) {
      removal.value = removal.value === "1" ? "0" : "1";
    }
    render();
  });

  thumbnail.addEventListener("error", () => {
    clearPreview();
    render();
  });
});
