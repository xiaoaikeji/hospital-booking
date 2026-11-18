document.addEventListener("show.bs.tooltip", (event) => {
  const text = event.target;
  if (!text.matches("[data-list-text]")) return;

  if (text.scrollWidth <= text.clientWidth && text.scrollHeight <= text.clientHeight) {
    event.preventDefault();
  }
});
