async function fetchCode(url, signal) {
  const response = await fetch(url, { signal, credentials: "same-origin", headers: { Accept: "image/png,image/jpeg,application/json" } });
  const type = response.headers.get("Content-Type")?.split(";")[0];
  if (type === "application/json") {
    const result = await response.json();
    throw new Error(result.error || "暂时无法获取二维码。");
  }
  if (!response.ok || !["image/png", "image/jpeg"].includes(type)) {
    throw new Error("未能获取二维码，请检查应用的授权与版本后重试。");
  }
  return response.blob();
}

async function loadPanel(panel) {
  const refresh = panel.querySelector("button[type='submit']");
  refresh.disabled = true;
  try {
    await Promise.all(Array.from(panel.querySelectorAll("[data-code-src]"), async (tile) => {
      const status = tile.querySelector("[role='status']");
      const image = tile.querySelector("img");
      try {
        const blob = await fetchCode(tile.dataset.codeSrc);
        image.src = URL.createObjectURL(blob);
        await image.decode();
        status.hidden = true;
        image.hidden = false;
      } catch (error) {
        if (image.src) {
          URL.revokeObjectURL(image.src);
          image.removeAttribute("src");
        }
        status.textContent = error instanceof TypeError || error.name === "EncodingError" ? "图片暂不可读，请刷新重试。" : error.message;
      }
    }));
  } finally {
    refresh.disabled = false;
  }
}

const overviewCodes = document.querySelector("[data-qrcode-panel]");
if (overviewCodes) loadPanel(overviewCodes);

document.addEventListener("submit", async (event) => {
  const form = event.target.closest("[data-qrcode-refresh]");
  if (!form) return;
  event.preventDefault();
  const panel = form.closest("[data-qrcode-panel]");
  const button = form.querySelector("button");
  if (button.disabled) return;
  button.disabled = true;
  const alert = panel.querySelector("[role='alert']");
  alert.hidden = true;
  try {
    const response = await fetch(form.action, { method: "POST", credentials: "same-origin", body: new FormData(form),
      headers: { "X-Requested-With": "XMLHttpRequest", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || "" } });
    if (!response.ok || response.redirected) throw new Error();
    const html = new DOMParser().parseFromString(await response.text(), "text/html");
    const updated = html.querySelector("[data-qrcode-panel]");
    if (!updated) throw new Error();
    panel.querySelectorAll("img[src]").forEach((image) => URL.revokeObjectURL(image.src));
    panel.replaceWith(updated);
    await loadPanel(updated);
  } catch {
    alert.textContent = "刷新失败，请检查登录状态后重试。";
    alert.hidden = false;
    button.disabled = false;
  }
});

const modal = document.getElementById("app-qrcode");

if (modal) {
  const image = modal.querySelector("img");
  const status = modal.querySelector("[role='status']");
  const download = modal.querySelector("[data-download]");
  const retry = modal.querySelector("[data-retry]");
  let trigger;
  let request;
  let imageUrl;

  async function loadCode() {
    const { qrcodeTitle, qrcodeUrl, appName, appid } = trigger.dataset;
    modal.querySelector("#app-qrcode-title").textContent = qrcodeTitle;
    modal.querySelector("[data-app-name]").textContent = appName;
    image.alt = qrcodeTitle;
    status.textContent = "正在获取" + qrcodeTitle + "…";
    retry.hidden = true;
    const controller = new AbortController();
    request = controller;

    try {
      const blob = await fetchCode(qrcodeUrl, controller.signal);
      if (controller.signal.aborted) return;
      imageUrl = URL.createObjectURL(blob);
      image.src = download.href = imageUrl;
      download.download = appid + "-" + qrcodeTitle + (blob.type === "image/png" ? ".png" : ".jpg");
      image.hidden = download.hidden = false;
      status.textContent = "";
    } catch (error) {
      if (!controller.signal.aborted) {
        status.textContent = error.message;
        retry.hidden = false;
      }
    }
  }

  retry.addEventListener("click", loadCode);
  modal.addEventListener("show.bs.modal", (event) => {
    trigger = event.relatedTarget;
    loadCode();
  });

  modal.addEventListener("hidden.bs.modal", () => {
    request?.abort();
    image.hidden = download.hidden = retry.hidden = true;
    image.removeAttribute("src");
    download.removeAttribute("href");
    if (imageUrl) URL.revokeObjectURL(imageUrl);
    imageUrl = null;
  });
}
