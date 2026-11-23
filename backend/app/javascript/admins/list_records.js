document.addEventListener("show.bs.tooltip", (event) => {
  const text = event.target;
  if (!text.matches("[data-list-text]")) return;

  if (text.scrollWidth <= text.clientWidth && text.scrollHeight <= text.clientHeight) {
    event.preventDefault();
  }
});

function hideUnavailableAvatar(image) {
  if (image instanceof HTMLImageElement && image.hasAttribute("data-customer-avatar")) image.hidden = true;
}

document.addEventListener("error", (event) => hideUnavailableAvatar(event.target), true);
document.querySelectorAll("img[data-customer-avatar]").forEach((image) => {
  if (image.complete && !image.naturalWidth) hideUnavailableAvatar(image);
});
