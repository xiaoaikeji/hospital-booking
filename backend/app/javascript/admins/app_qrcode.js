const modal = document.getElementById("app-qrcode");

if (modal) {
  const image = modal.querySelector("img");
  const status = modal.querySelector("[role='status']");
  const download = modal.querySelector("[data-download]");
  let request;
  let imageUrl;

  modal.addEventListener("show.bs.modal", async (event) => {
    const button = event.relatedTarget;
    modal.querySelector("[data-app-name]").textContent = button.dataset.appName;
    status.textContent = "正在获取正式版小程序码…";
    const controller = new AbortController();
    request = controller;

    try {
      const response = await fetch(button.dataset.qrcodeUrl, { signal: controller.signal, credentials: "same-origin" });
      const contentType = response.headers.get("Content-Type") || "";
      if (contentType.includes("application/json")) {
        const result = await response.json();
        throw new Error(result.error || "暂时无法获取小程序码。");
      }
      if (!response.ok || !["image/png", "image/jpeg"].includes(contentType)) {
        throw new Error("未能读取小程序码，请检查登录状态后重试。");
      }
      const blob = await response.blob();
      if (controller.signal.aborted) return;
      imageUrl = URL.createObjectURL(blob);
      image.src = download.href = imageUrl;
      download.download = button.dataset.appid + (contentType === "image/png" ? "-release.png" : "-release.jpg");
      image.hidden = download.hidden = false;
      status.textContent = "";
    } catch (error) {
      if (!controller.signal.aborted) status.textContent = error.message;
    }
  });

  modal.addEventListener("hidden.bs.modal", () => {
    request?.abort();
    image.hidden = download.hidden = true;
    image.removeAttribute("src");
    download.removeAttribute("href");
    if (imageUrl) URL.revokeObjectURL(imageUrl);
    imageUrl = null;
  });
}
