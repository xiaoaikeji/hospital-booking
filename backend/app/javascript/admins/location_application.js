document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("location-application");
  if (!form) return;
  const content = form.querySelector("textarea");
  const counter = form.querySelector("[data-location-count]");
  const count = () => { counter.textContent = Array.from(content.value).length; };
  content.addEventListener("input", count);
  form.querySelectorAll("[data-location-example]").forEach(button => {
    button.addEventListener("click", () => {
      content.value = button.dataset.locationExample;
      count();
      content.focus();
    });
  });
  const pictures = form.querySelector("[data-location-pictures]");
  const pictureList = form.querySelector("[data-location-picture-list]");
  const pictureTemplate = form.querySelector("[data-location-picture]");
  let previewURLs = [];

  function showPictures() {
    previewURLs.forEach(url => URL.revokeObjectURL(url));
    previewURLs = [];
    const files = Array.from(pictures.files);
    pictureList.hidden = files.length === 0;
    pictureList.replaceChildren(...files.map((file, index) => {
      const tile = pictureTemplate.content.firstElementChild.cloneNode(true);
      const url = URL.createObjectURL(file);
      previewURLs.push(url);
      tile.querySelector("img").src = url;
      const caption = tile.querySelector("span");
      caption.textContent = caption.title = file.name;
      const remove = tile.querySelector("button");
      remove.setAttribute("aria-label", "移除 " + file.name);
      remove.addEventListener("click", () => {
        const selection = new DataTransfer();
        files.forEach((item, position) => { if (position !== index) selection.items.add(item); });
        pictures.files = selection.files;
        showPictures();
        (pictureList.querySelectorAll("button")[Math.min(index, selection.files.length - 1)] || pictures).focus();
      });
      return tile;
    }));
  }

  pictures.addEventListener("change", showPictures);

  form.addEventListener("submit", event => {
    if (form.dataset.confirmed === "true") return;
    event.preventDefault();
    window.tabler.Modal.getOrCreateInstance(document.getElementById("location-apply-confirm")).show();
  });
});
