(() => {
  const section = document.getElementById("template-library");
  if (!section?.dataset.source) return;
  const button = document.getElementById("refresh-templates");
  let generation = 0;
  async function refresh() {
    const request = ++generation;
    button.disabled = true;
    document.getElementById("template-feedback").textContent = "";
    try {
      const response = await fetch(section.dataset.source);
      if (!response.ok || response.redirected) throw new Error();
      const html = await response.text();
      if (request === generation && !document.querySelector(".modal.show")) section.innerHTML = html;
    } catch {
      if (request === generation) document.getElementById("template-feedback").textContent = "刷新失败，请重试。";
    } finally { button.disabled = false; }
  }
  section.addEventListener("show.bs.modal", () => { generation++; });
  button.addEventListener("click", refresh);
  refresh();
})();
