document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-editor]");
  if (!root) return;
  const reply = JSON.parse(root.dataset.reply), input = JSON.parse(root.dataset.input);
  const items = root.querySelector("[data-reply-items]"), preview = root.querySelector("[data-reply-preview]");
  const error = root.querySelector("[data-reply-error]");
  const scope = document.getElementById("reply-scope");
  const save = root.querySelector("[data-reply-save]");
  const variables = JSON.parse(root.dataset.variables || "{}");
  const examples = JSON.parse(root.dataset.examples || "{}");
  let busy = false, dirty = false, lastTextArea = null;
  const node = (tag, cls, text) => { const n = document.createElement(tag); n.className = cls; if (text) n.textContent = text; return n; };
  function field(parent, title, key, value, multiline = false) {
    const group = node("div", "mb-3");
    const label = node("label", "form-label required", title);
    const control = node(multiline ? "textarea" : "input", "form-control");
    control.id = "reply-" + crypto.randomUUID();
    label.htmlFor = control.id;
    control.value = value || "";
    control.required = true;
    control.dataset.content = key;
    control.dataset.replyField = key;
    control.dataset.requiredMessage = "请填写" + title;
    if (multiline) {
      control.rows = 3;
      control.addEventListener("focus", () => { lastTextArea = control; });
    }
    group.append(label, control);
    parent.append(group);
  }

  function focusNode(control) { return control.tomselect?.focus_node || control; }

  function setFieldError(control, message) {
    const id = control.id + "-error";
    let feedback = document.getElementById(id);
    const decorated = control.tomselect?.wrapper || control;
    decorated.classList.toggle("is-invalid", Boolean(message));
    for (const element of new Set([control, focusNode(control)])) {
      if (message) {
        element.setAttribute("aria-invalid", "true");
        element.setAttribute("aria-describedby", id);
      } else {
        element.removeAttribute("aria-invalid");
        element.removeAttribute("aria-describedby");
      }
    }
    if (!message) {
      feedback?.remove();
      return;
    }
    if (!feedback) {
      feedback = node("div", "invalid-feedback d-block");
      feedback.id = id;
      decorated.after(feedback);
    }
    feedback.textContent = message;
  }

  function validateFields() {
    let firstInvalid;
    root.querySelectorAll("[data-reply-field]").forEach(control => {
      const message = control.required && !control.value.trim() ? control.dataset.requiredMessage : "";
      setFieldError(control, message);
      if (message && !firstInvalid) firstInvalid = control;
    });
    if (firstInvalid) focusNode(firstInvalid).focus();
    return !firstInvalid;
  }

  function showSaveError(error) {
    const container = Number.isInteger(error.messageIndex)
      ? items.querySelector('[data-message-index="' + error.messageIndex + '"]')
      : root;
    const control = [...(container?.querySelectorAll("[data-reply-field]") || [])].find(el => el.dataset.replyField === error.field);
    if (!control) {
      showError(error.message);
      return;
    }
    setFieldError(control, error.message);
    focusNode(control).focus();
  }
  function read() {
    const name = document.getElementById("reply-name");
    if (name) reply.name = name.value;
    items.querySelectorAll("[data-message-index]").forEach(box => {
      const m = reply.messages[Number(box.dataset.messageIndex)];
      box.querySelectorAll("[data-content]").forEach(control => { m.content[control.dataset.content] = control.value; });
    });
  }
  function drawPreview() {
    read(); preview.replaceChildren();
    reply.messages.forEach(m => {
      const box = node("div", "card card-body mb-2 text-break"); box.style.whiteSpace = "pre-wrap";
      const rendered = window.NotificationVariables ? window.NotificationVariables.render(m.content.text, variables, examples) : m.content.text;
      box.textContent = m.type === "text" ? (rendered || "当前示例无文字内容") : [m.content.title || "小程序卡片", m.content.appid, m.content.pagepath, m.content.thumb_media_id ? "封面已选择" : "请选择封面"].filter(Boolean).join("\n");
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
      const tools = node("div", "d-flex flex-wrap justify-content-end align-items-center gap-2 mb-3");
      tools.append(node("strong", "me-auto", `第 ${i + 1} 条 · ${m.type === "text" ? "文字" : "小程序卡片"}`));
      [["上移", -1], ["下移", 1], ["删除", 0]].forEach(([label, by]) => {
        const b = node("button", "btn btn-sm", label); b.type = "button";
        b.disabled = busy || (by !== 0 && (i + by < 0 || i + by >= reply.messages.length));
        b.onclick = () => {
          if (busy) return;
          dirty = true;
          read();
          if (!by) reply.messages.splice(i, 1);
          else [reply.messages[i], reply.messages[i + by]] = [reply.messages[i + by], reply.messages[i]];
          draw();
        };
        tools.append(b);
      }); box.append(tools);
      if (m.type === "text") field(box, "文字内容", "text", m.content.text, true);
      else {
        field(box, "卡片标题", "title", m.content.title);
        box.append(root.querySelector("[data-reply-card-template]").content.cloneNode(true));
        const miniSelect = box.querySelector("select");
        miniSelect.value = m.content.appid || "";
        miniSelect.id = "mini-" + crypto.randomUUID();
        miniSelect.previousElementSibling.htmlFor = miniSelect.id;
        field(box, "页面路径", "pagepath", m.content.pagepath);
        const label = node("label", "form-label required", "卡片封面（上传到当前公众号）");
        const file = node("input", "form-control");
        file.type = "file";
        file.accept = "image/png,image/jpeg";
        file.id = "cover-" + crypto.randomUUID();
        file.required = !m.content.thumb_media_id;
        file.dataset.replyField = "thumb_media_id";
        file.dataset.requiredMessage = "请上传卡片封面";
        label.htmlFor = file.id;
        file.onchange = async () => {
          const selected = file.files[0];
          if (!selected || busy) return;
          busy = true;
          save.disabled = true;
          try {
            const data = new FormData();
            data.append("file", selected);
            const result = await request(root.dataset.media, "POST", data);
            m.content.thumb_media_id = result.media_id;
            m.proof = result.proof;
            if (m.previewUrl) URL.revokeObjectURL(m.previewUrl);
            m.previewUrl = URL.createObjectURL(selected);
            file.required = false;
            drawPreview();
          } catch (e) {
            file.value = "";
            setFieldError(file, e.message);
          } finally {
            busy = false;
            save.disabled = false;
          }
        };
        box.append(label, file);
      }
      box.addEventListener("input", () => { dirty = true; drawPreview(); });
      items.append(box);
      window.initializeAdminSelects(box);
    }); drawPreview();
  }
  function showError(text) { error.textContent = text; error.hidden = !text; }
  async function request(url, method, data) {
    const headers = { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" };
    if (!(data instanceof FormData)) { headers["Content-Type"] = "application/json"; data = JSON.stringify(data); }
    const response = await fetch(url, { method, headers, body: data });
    const result = await response.json();
    if (!response.ok) {
      const failure = new Error(result.error || "保存失败，请核对后重试");
      failure.field = result.field;
      failure.messageIndex = result.message_index;
      throw failure;
    }
    return result;
  }
  root.querySelectorAll("[data-reply-add]").forEach(button => { button.onclick = () => {
    if (busy) return; dirty = true; read(); reply.messages.push({ id: crypto.randomUUID(), type: button.dataset.replyAdd, content: {} }); draw();
  }; });
  function toggleScope() { root.querySelector("[data-reply-impacts]")?.classList.toggle("d-none", scope.value !== "all"); }
  scope?.addEventListener("change", toggleScope); if (scope) toggleScope();
  document.getElementById("reply-name")?.addEventListener("input", () => { dirty = true; drawPreview(); });
  function clearChangedField(event) {
    const control = event.target;
    if (control.matches("[data-reply-field][aria-invalid=true]")) setFieldError(control, "");
  }
  root.addEventListener("input", clearChangedField);
  root.addEventListener("change", clearChangedField);
  root.querySelectorAll("[data-insert-variable]").forEach(button => {
    button.onclick = () => {
      if (busy) return;
      if (!lastTextArea || !document.contains(lastTextArea)) lastTextArea = items.querySelector('[data-content="text"]');
      if (!lastTextArea) {
        root.querySelector('[data-reply-add="text"]').click();
        lastTextArea = items.querySelector('[data-content="text"]');
      }
      if (!lastTextArea) return;
      const token = "{" + button.dataset.insertVariable + "}";
      lastTextArea.setRangeText(token, lastTextArea.selectionStart, lastTextArea.selectionEnd, "end");
      lastTextArea.dispatchEvent(new Event("input", { bubbles: true })); lastTextArea.focus();
    };
  });
  document.getElementById("restore-content-form")?.addEventListener("submit", () => { dirty = false; });
  window.addEventListener("beforeunload", event => { if (dirty) { event.preventDefault(); event.returnValue = ""; } });
  save.onclick = async () => {
    if (busy) return;
    showError("");
    if (!validateFields()) return;
    read();
    busy = true;
    window.adminForms.setBusy(root, true);
    try {
      const result = await request(root.dataset.save, input.id ? "PATCH" : "POST", { [root.dataset.payloadKey || "reply_content"]: { ...input, scope: scope?.value || input.scope, name: reply.name, messages: reply.messages } });
      dirty = false;
      if (root.dataset.inline === "true" && window.opener) { window.opener.postMessage({ type: "booking.reply.saved", ...result, appId: new URL(location.href).pathname.split("/")[3] }, location.origin); window.close(); }
      else location.assign(root.dataset.back);
    } catch (e) {
      showSaveError(e);
    } finally {
      busy = false;
      window.adminForms.setBusy(root, false);
    }
  };
  draw();
});
