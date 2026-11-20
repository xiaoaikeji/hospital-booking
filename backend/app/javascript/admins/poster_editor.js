document.addEventListener("DOMContentLoaded", async () => {
  const form = document.querySelector("#poster-editor");
  if (!form) return;
  const layout = window.BookingPosterLayout;
  const canvas = form.querySelector("[data-poster-canvas]");
  const marker = form.querySelector("[data-poster-box]");
  const status = form.querySelector("[data-poster-status]");
  const preview = form.querySelector("[data-poster-preview]");
  const download = form.querySelector("[data-poster-download]");
  const fields = ["qr_x", "qr_y", "qr_size"].map((name) => form.elements[`poster[${name}]`]);
  const field = (name) => form.elements[`poster[${name}]`];
  const kind = field("target_kind"), app = field("app_id"), channel = field("official_account_qrcode_id");
  const backgroundInput = field("background");
  const appOptions = Array.from(app.options).map((option) => option.cloneNode(true));
  const codeOptions = Array.from(channel.options).map((option) => option.cloneNode(true));
  let background, code, generation = 0, drag;
  const needsSave = () => backgroundInput.files.length > 0;
  const canPreview = () => Boolean(background) && !needsSave();
  const message = (text, failed = false) => {
    status.textContent = text;
    status.classList.toggle("text-danger", failed);
    status.classList.toggle("text-secondary", !failed);
  };
  function replaceOptions(select, options) {
    const value = select.value;
    select.tomselect?.destroy();
    select.replaceChildren(...options.map((option) => option.cloneNode(true)));
    select.value = options.some((option) => option.value === value) ? value : "";
    window.initializeAdminSelects(form);
  }
  function invalidatePreview(text) {
    generation += 1;
    code = null;
    drag = null;
    preview.disabled = !canPreview();
    preview.textContent = "预览海报";
    message(needsSave() ? "已选择新底图，请先保存，完成图片方向校正后再预览。" : text);
    render();
  }
  function targetsChanged(source) {
    if (source === kind) replaceOptions(app, appOptions.filter((option) => !option.value || option.dataset.appType === kind.value));
    if (source === kind || source === app) replaceOptions(channel, codeOptions.filter((option) => !option.value || option.dataset.appId === app.value));
    form.querySelectorAll("[data-target-kind]").forEach((area) => { area.hidden = area.dataset.targetKind !== kind.value; });
    invalidatePreview("扫码目标已更新，请预览海报。");
  }
  function render() {
    canvas.hidden = !canPreview();
    download.disabled = true;
    marker.hidden = true;
    if (canvas.hidden) return;
    let box;
    try {
      box = layout.box(canvas, fields.map((input) => input.value));
    } catch (error) {
      marker.hidden = true;
      download.disabled = true;
      layout.draw(canvas, background, null, null);
      message(error.message, true);
      return;
    }
    layout.draw(canvas, background, code, box);
    marker.hidden = false;
    Object.assign(marker.style, { left: `${box.x / canvas.width * 100}%`, top: `${box.y / canvas.height * 100}%`, width: `${box.size / canvas.width * 100}%`, height: `${box.size / canvas.height * 100}%` });
    marker.classList.toggle("has-code", Boolean(code));
    marker.querySelector("[data-poster-placeholder]").hidden = Boolean(code);
    download.disabled = !code;
  }
  form.querySelectorAll("[data-code-input]").forEach((input) => input.addEventListener(input.tagName === "SELECT" ? "change" : "input", () => targetsChanged(input)));
  fields.forEach((input) => input.addEventListener("input", render));
  backgroundInput.addEventListener("change", () => invalidatePreview("请预览海报。"));
  const point = (event) => {
    const rect = canvas.getBoundingClientRect();
    return { x: (event.clientX - rect.left) * canvas.width / rect.width, y: (event.clientY - rect.top) * canvas.height / rect.height };
  };
  marker.addEventListener("pointerdown", (event) => {
    if (!canPreview()) return;
    const box = layout.box(canvas, fields.map((input) => input.value));
    drag = { point: point(event), box, resize: event.target.classList.contains("poster-code-handle") };
    marker.setPointerCapture(event.pointerId);
    event.preventDefault();
  });
  marker.addEventListener("pointermove", (event) => {
    if (!drag) return;
    const next = point(event), { point: start, box, resize } = drag;
    const clamp = (n, max) => Math.round(Math.min(max, Math.max(0, n)));
    if (resize) {
      fields[2].value = Math.max(1, clamp(box.size + Math.max(next.x - start.x, next.y - start.y), Math.min(canvas.width - box.x, canvas.height - box.y)));
    } else {
      fields[0].value = clamp(box.x + next.x - start.x, canvas.width - box.size);
      fields[1].value = clamp(box.y + next.y - start.y, canvas.height - box.size);
    }
    render();
  });
  ["pointerup", "pointercancel", "lostpointercapture"].forEach((type) => marker.addEventListener(type, () => { drag = null; }));
  preview.addEventListener("click", async () => {
    if (!canPreview()) return;
    const current = ++generation;
    preview.disabled = true;
    message("正在获取扫码图片…");
    try {
      layout.box(canvas, fields.map((input) => input.value));
      const target = Object.fromEntries(["target_kind", "app_id", "official_account_qrcode_id", "page_path", "page_query"].map((name) => [name, field(name).value]));
      const response = await fetch(form.dataset.codeUrl, { method: "POST", headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }, body: JSON.stringify({ target }) });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "取码失败，请重试。");
      const image = await layout.image(data.image);
      if (generation !== current) return;
      code = image;
      render();
      message("预览已就绪，可下载原图 PNG。位置和目标修改后请保存。");
      preview.textContent = "重新预览";
    } catch (error) {
      if (generation !== current) return;
      code = null; render();
      message(`${error.message} 已保留填写内容，可重试。`, true);
      preview.textContent = "重试预览";
    } finally {
      if (generation === current) preview.disabled = !canPreview();
    }
  });
  download.addEventListener("click", () => {
    if (!canPreview() || !code || download.disabled) return;
    const current = generation;
    render();
    if (download.disabled) return;
    canvas.toBlob((blob) => {
      if (generation !== current || !canPreview()) return;
      if (!blob) { message("PNG 生成失败，请重试。", true); return; }
      const url = URL.createObjectURL(blob), link = document.createElement("a");
      link.href = url;
      link.download = `${field("name").value || "海报"}.png`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }, "image/png");
  });
  targetsChanged(kind);
  try {
    background = await layout.image(form.dataset.background);
    canvas.width = background.naturalWidth;
    canvas.height = background.naturalHeight;
    preview.disabled = !canPreview();
    render();
  } catch (error) { message(error.message, true); }
});
