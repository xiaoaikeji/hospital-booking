document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-editor]");
  if (!root) return;
  const reply = JSON.parse(root.dataset.reply), input = JSON.parse(root.dataset.input);
  const items = root.querySelector("[data-reply-items]"), preview = root.querySelector("[data-reply-preview]");
  const error = root.querySelector("[data-reply-error]");
  const scope = document.getElementById("reply-scope");
  let busy = false;
  const node = (tag, cls, text) => { const n = document.createElement(tag); n.className = cls; if (text) n.textContent = text; return n; };
  function field(parent, title, key, value, multiline = false) {
    const label = node("label", "form-label", title);
    const control = node(multiline ? "textarea" : "input", "form-control mb-3");
    control.id = "reply-" + crypto.randomUUID(); label.htmlFor = control.id;
    control.value = value || ""; control.dataset.content = key;
    if (multiline) control.rows = 3;
    parent.append(label, control); return control;
  }
  function read() {
    reply.name = document.getElementById("reply-name").value;
    items.querySelectorAll("[data-message-index]").forEach(box => {
      const m = reply.messages[Number(box.dataset.messageIndex)];
      box.querySelectorAll("[data-content]").forEach(control => { m.content[control.dataset.content] = control.value; });
    });
  }
  function drawPreview() {
    read(); preview.replaceChildren();
    reply.messages.forEach(m => {
      const box = node("div", "card card-body mb-2 text-break"); box.style.whiteSpace = "pre-wrap";
      box.textContent = m.type === "text" ? m.content.text || "文字预览" : [m.content.title || "小程序卡片", m.content.appid, m.content.pagepath, m.content.thumb_media_id ? "封面已选择" : "请选择封面"].filter(Boolean).join("\n");
      if (m.type === "miniprogrampage" && m.content.thumb_media_id) {
        const img = document.createElement("img"); img.className = "rounded mt-2 img-fluid"; img.alt = "小程序卡片封面";
        img.src = m.previewUrl || root.dataset.image + "?" + new URLSearchParams({ media_id: m.content.thumb_media_id, proof: m.proof || "" });
        img.onerror = () => { img.hidden = true; }; box.append(img);
      }
      preview.append(box);
    });
  }
  function draw() {
    items.querySelectorAll("select").forEach(select => select.tomselect?.destroy());
    items.replaceChildren();
    reply.messages.forEach((m, i) => {
      const box = node("div", "border rounded p-3 mb-3"); box.dataset.messageIndex = i;
      const tools = node("div", "d-flex flex-wrap align-items-center gap-2 mb-3");
      tools.append(node("strong", "me-auto", `第 ${i + 1} 条 · ${m.type === "text" ? "文字" : "小程序卡片"}`));
      [["上移", -1], ["下移", 1], ["删除", 0]].forEach(([label, by]) => {
        const b = node("button", "btn btn-sm", label); b.type = "button";
        b.disabled = busy || (by !== 0 && (i + by < 0 || i + by >= reply.messages.length));
        b.onclick = () => { read(); if (!by) reply.messages.splice(i, 1); else [reply.messages[i], reply.messages[i + by]] = [reply.messages[i + by], reply.messages[i]]; draw(); };
        tools.append(b);
      }); box.append(tools);
      if (m.type === "text") field(box, "文字内容", "text", m.content.text, true);
      else {
        field(box, "卡片标题", "title", m.content.title);
        box.append(root.querySelector("[data-reply-card-template]").content.cloneNode(true));
        const miniSelect = box.querySelector("select"); miniSelect.value = m.content.appid || "";
        miniSelect.id = "mini-" + crypto.randomUUID(); miniSelect.previousElementSibling.htmlFor = miniSelect.id; miniSelect.setAttribute("aria-label", "目标小程序");
        field(box, "页面路径", "pagepath", m.content.pagepath);
        const label = node("label", "form-label", "卡片封面（上传到当前公众号）");
        const file = node("input", "form-control"); file.type = "file"; file.accept = "image/png,image/jpeg";
        file.id = "cover-" + crypto.randomUUID(); label.htmlFor = file.id;
        const hint = node("div", "form-hint", m.content.thumb_media_id ? "封面已选择" : "请选择 JPG 或 PNG 图片");
        file.onchange = async () => {
          if (!file.files[0]) return;
          busy = true; root.querySelector("[data-reply-save]").disabled = true;
          try {
            const data = new FormData(); data.append("file", file.files[0]);
            const result = await request(root.dataset.media, "POST", data);
            m.content.thumb_media_id = result.media_id; m.proof = result.proof; if (m.previewUrl) URL.revokeObjectURL(m.previewUrl); m.previewUrl = URL.createObjectURL(file.files[0]); hint.textContent = "封面已选择"; drawPreview();
          } catch (e) { showError(e.message); }
          finally { busy = false; root.querySelector("[data-reply-save]").disabled = false; }
        };
        box.append(label, file, hint);
      }
      box.addEventListener("input", drawPreview); items.append(box);
      box.querySelectorAll("select").forEach(select => { if (window.TomSelect) new window.TomSelect(select, { create: false, controlInput: null, dropdownParent: "body" }).focus_node.setAttribute("aria-label", select.getAttribute("aria-label") || "目标小程序"); });
    }); drawPreview();
  }
  function showError(text) { error.textContent = text; error.hidden = !text; }
  async function request(url, method, data) {
    const headers = { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" };
    if (!(data instanceof FormData)) { headers["Content-Type"] = "application/json"; data = JSON.stringify(data); }
    const response = await fetch(url, { method, headers, body: data });
    const result = await response.json(); if (!response.ok) throw new Error(result.error || "保存失败，请核对后重试"); return result;
  }
  root.querySelectorAll("[data-reply-add]").forEach(button => { button.onclick = () => {
    if (busy) return; read(); reply.messages.push({ id: crypto.randomUUID(), type: button.dataset.replyAdd, content: {} }); draw();
  }; });
  function toggleScope() { const impact = root.querySelector("[data-reply-impacts]"); if (impact) impact.hidden = scope.value !== "all"; }
  scope?.addEventListener("change", toggleScope); if (scope) toggleScope();
  document.getElementById("reply-name").addEventListener("input", drawPreview);
  root.querySelector("[data-reply-save]").onclick = async () => {
    if (busy) return; read(); busy = true; showError("");
    const button = root.querySelector("[data-reply-save]"); button.disabled = true;
    try {
      const result = await request(root.dataset.save, input.id ? "PATCH" : "POST", { reply_content: { ...input, scope: scope?.value || input.scope, name: reply.name, messages: reply.messages } });
      if (root.dataset.inline === "true" && window.opener) { window.opener.postMessage({ type: "booking.reply.saved", ...result, appId: new URL(location.href).pathname.split("/")[3] }, location.origin); window.close(); }
      else location.assign(root.dataset.back);
    } catch (e) { showError(e.message); } finally { busy = false; button.disabled = false; }
  };
  draw();
});
