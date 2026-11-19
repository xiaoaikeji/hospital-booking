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
      const response = await fetch(qrcodeUrl, { signal: controller.signal, credentials: "same-origin", headers: { Accept: "image/png,image/jpeg,application/json" } });
      const contentType = response.headers.get("Content-Type")?.split(";")[0];
      if (contentType === "application/json") {
        const result = await response.json();
        throw new Error(result.error || "暂时无法获取二维码。");
      }
      if (!response.ok || !["image/png", "image/jpeg"].includes(contentType)) {
        throw new Error("未能获取二维码，请检查应用的授权与版本后重试。");
      }
      const blob = await response.blob();
      if (controller.signal.aborted) return;
      imageUrl = URL.createObjectURL(blob);
      image.src = download.href = imageUrl;
      download.download = appid + "-" + qrcodeTitle + (contentType === "image/png" ? ".png" : ".jpg");
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
