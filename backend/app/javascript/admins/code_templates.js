(() => {
  const library = document.getElementById("template-library");
  if (!library?.dataset.source) return;
  const button = document.getElementById("refresh-templates");
  const feedback = document.getElementById("template-feedback");
  let pendingHtml = null;
  function applyRefresh() {
    if (pendingHtml !== null && !library.querySelector(".modal.show")) {
      library.innerHTML = pendingHtml;
      pendingHtml = null;
    }
  }
  async function refresh() {
    if (button.disabled) return;
    button.disabled = true;
    feedback.textContent = "正在刷新微信数据…";
    try {
      const response = await fetch(library.dataset.source);
      if (!response.ok || response.redirected) throw new Error();
      pendingHtml = await response.text();
      applyRefresh();
      feedback.textContent = "";
    } catch {
      feedback.textContent = "微信数据刷新失败，可再次刷新。";
    } finally {
      button.disabled = false;
    }
  }
  library.addEventListener("hidden.bs.modal", applyRefresh);
  button.addEventListener("click", refresh);
  refresh();
})();
