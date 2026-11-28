document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-reply-editor]");
  if (!root) return;
  const reply = JSON.parse(root.dataset.reply), input = JSON.parse(root.dataset.input);
  const items = root.querySelector("[data-reply-items]"), preview = root.querySelector("[data-reply-preview]");
  const error = root.querySelector("[data-reply-error]");
  const scope = document.getElementById("reply-scope");
  const interval = document.getElementById("send-interval");
  const save = root.querySelector("[data-reply-save]");
  const variables = JSON.parse(root.dataset.variables || "{}");
  const examples = JSON.parse(root.dataset.examples || "{}");
  const variableDrawer = root.querySelector("[data-notification-variables]");
  const accordionToggle = root.querySelector("[data-reply-accordion-toggle]");
  let busy = false, dirty = false, variableTarget = null, expandedMessage = reply.messages[0];
  interval?.addEventListener("input", () => { dirty = true; });
  const newId = () => crypto.randomUUID?.() ?? Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, "0")).join("");
  const node = (tag, cls, text) => { const n = document.createElement(tag); n.className = cls; if (text) n.textContent = text; return n; };
  function field(parent, title, key, value, multiline = false) {
    const group = node("div", "mb-3");
    const label = node("label", "form-label required", title);
    const control = node(multiline ? "textarea" : "input", "form-control");
    control.id = "reply-" + newId();
    label.htmlFor = control.id;
    control.value = value || "";
    control.required = true;
    control.dataset.content = key;
    control.dataset.replyField = key;
    control.dataset.requiredMessage = "请填写" + title;
    if (multiline) control.rows = Math.min(8, Math.max(3, control.value.split("\n").length));
    if (multiline && Object.keys(variables).length) {
      const header = node("div", "d-flex justify-content-between align-items-center gap-2 mb-2");
      label.classList.add("mb-0");
      const insert = node("button", "btn btn-sm", "插入变量");
      insert.type = "button";
      insert.dataset.bsToggle = "offcanvas";
      insert.dataset.bsTarget = "#" + variableDrawer.id;
      insert.setAttribute("aria-controls", variableDrawer.id);
      insert.addEventListener("click", () => { variableTarget = control; });
      header.append(label, insert);
      group.append(header);
    } else {
      group.append(label);
    }
    group.append(control);
    parent.append(group);
  }

  function focusNode(control) { return control.tomselect?.focus_node || control; }

  function focusField(control) {
    const panel = control.closest(".accordion-collapse");
    if (!panel || panel.classList.contains("show")) {
      focusNode(control).focus();
      return;
    }
    const transitioning = items.querySelector(".collapsing");
    if (transitioning) {
      const opening = document.getElementById(transitioning.getAttribute("aria-labelledby")).getAttribute("aria-expanded") === "true";
      transitioning.addEventListener(opening ? "shown.bs.collapse" : "hidden.bs.collapse", () => focusField(control), { once: true });
      return;
    }
    panel.addEventListener("shown.bs.collapse", () => focusNode(control).focus(), { once: true });
    window.tabler.Collapse.getOrCreateInstance(panel, { toggle: false }).show();
  }

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
      (decorated.closest(".input-group") || decorated).after(feedback);
    }
    feedback.textContent = message;
  }

  function validateFields() {
    let firstInvalid;
    root.querySelectorAll("[data-reply-field]").forEach(control => {
      let message = control.required && !control.value.trim() ? control.dataset.requiredMessage : "";
      if (control === interval && !interval.validity.valid) message = "请输入 0～" + interval.max + " 之间的整数分钟";
      setFieldError(control, message);
      if (message && !firstInvalid) firstInvalid = control;
    });
    if (firstInvalid) focusField(firstInvalid);
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
    focusField(control);
  }
  function read() {
    const name = document.getElementById("reply-name");
    if (name) reply.name = name.value;
    items.querySelectorAll("[data-message-index]").forEach(box => {
      const m = reply.messages[Number(box.dataset.messageIndex)];
      box.querySelectorAll("[data-content]").forEach(control => { m.content[control.dataset.content] = control.value; });
    });
  }
  const enabled = root.querySelector("[data-notice-enabled]");
  enabled?.addEventListener("change", () => { dirty = true; });
  let previewTimer, previewVersion = 0;
  function drawPreview() {
    read(); preview.replaceChildren();
    if (root.dataset.preview) {
      clearTimeout(previewTimer);
      const version = ++previewVersion;
      previewTimer = setTimeout(async () => {
        try {
          const result = await request(root.dataset.preview, "POST", { notification_content: { messages: reply.messages } });
          if (version !== previewVersion) return;
          for (const text of result.texts) {
            const box = node("div", "card card-body mb-2 text-break", text);
            box.style.whiteSpace = "pre-wrap";
            preview.append(box);
          }
        } catch (e) {
          if (version === previewVersion) preview.textContent = e.message;
        }
      }, 180);
      return;
    }
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
    items.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(help => window.tabler.Tooltip.getInstance(help)?.dispose());
    items.replaceChildren();
    items.hidden = reply.messages.length === 0;
    reply.messages.forEach((m, i) => {
      const box = node("div", "accordion-item");
      box.dataset.messageIndex = i;
      const expanded = m === expandedMessage;
      const panel = node("div", "accordion-collapse collapse" + (expanded ? " show" : ""));
      panel.id = `${items.id}-panel-${i}`;
      panel.dataset.bsParent = "#" + items.id;
      const header = node("div", "row g-0 align-items-center");
      const labelColumn = node("div", "col-12 col-sm");
      const heading = node("h3", "accordion-header");
      const toggle = node("button", "accordion-button" + (expanded ? "" : " collapsed"),
        `第 ${i + 1} 条 · ${m.type === "text" ? "文字" : "小程序卡片"}`);
      toggle.type = "button";
      toggle.id = `${items.id}-heading-${i}`;
      toggle.dataset.bsToggle = "collapse";
      toggle.dataset.bsTarget = "#" + panel.id;
      toggle.setAttribute("aria-controls", panel.id);
      toggle.setAttribute("aria-expanded", String(expanded));
      panel.setAttribute("aria-labelledby", toggle.id);
      toggle.append(accordionToggle.content.cloneNode(true));
      heading.append(toggle);
      labelColumn.append(heading);
      const toolColumn = node("div", "col-12 col-sm-auto px-3 pb-2 pb-sm-0");
      const tools = node("div", "btn-list justify-content-end");
      [["上移", -1], ["下移", 1], ["删除", 0]].forEach(([label, by]) => {
        const b = node("button", "btn btn-sm" + (by ? "" : " btn-outline-danger"), label); b.type = "button";
        b.setAttribute("aria-label", `${label}第 ${i + 1} 条`);
        b.disabled = busy || (by !== 0 && (i + by < 0 || i + by >= reply.messages.length));
        b.onclick = () => {
          if (busy) return;
          dirty = true;
          read();
          if (!by) {
            reply.messages.splice(i, 1);
            if (expandedMessage === m) expandedMessage = reply.messages[Math.min(i, reply.messages.length - 1)];
            if (m.previewUrl) URL.revokeObjectURL(m.previewUrl);
          } else {
            [reply.messages[i], reply.messages[i + by]] = [reply.messages[i + by], reply.messages[i]];
          }
          draw();
        };
        tools.append(b);
      });
      toolColumn.append(tools);
      header.append(labelColumn, toolColumn);
      const body = node("div", "accordion-body");
      if (m.type === "text") field(body, "文字内容", "text", m.content.text, true);
      else {
        field(body, "卡片标题", "title", m.content.title);
        body.append(root.querySelector("[data-reply-card-template]").content.cloneNode(true));
        const miniSelect = body.querySelector("select");
        miniSelect.value = m.content.appid || "";
        miniSelect.id = "mini-" + newId();
        miniSelect.previousElementSibling.htmlFor = miniSelect.id;
        field(body, "页面路径", "pagepath", m.content.pagepath);
        const label = node("label", "form-label required mb-0", "卡片封面（上传到当前公众号）");
        const coverHeader = node("div", "d-flex flex-wrap align-items-center gap-1 mb-2");
        coverHeader.append(label, root.querySelector("[data-reply-cover-help]").content.cloneNode(true));
        const file = node("input", "form-control");
        file.type = "file";
        file.accept = root.dataset.coverTypes;
        file.id = "cover-" + newId();
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
        body.append(coverHeader, file);
      }
      panel.append(body);
      box.append(header, panel);
      panel.addEventListener("show.bs.collapse", () => { expandedMessage = m; });
      panel.addEventListener("hide.bs.collapse", () => { if (expandedMessage === m) expandedMessage = null; });
      box.addEventListener("input", () => { dirty = true; drawPreview(); });
      items.append(box);
      window.initializeAdminSelects(box);
      box.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(help => window.tabler.Tooltip.getOrCreateInstance(help));
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
    if (busy) return;
    dirty = true;
    read();
    expandedMessage = { id: newId(), type: button.dataset.replyAdd, content: {} };
    reply.messages.push(expandedMessage);
    draw();
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
  variableDrawer.querySelectorAll("[data-insert-variable]").forEach(button => {
    button.onclick = () => {
      if (busy || !variableTarget?.isConnected) return;
      const token = "{" + button.dataset.insertVariable + "}";
      variableTarget.setRangeText(token, variableTarget.selectionStart, variableTarget.selectionEnd, "end");
      variableTarget.dispatchEvent(new Event("input", { bubbles: true }));
    };
  });
  variableDrawer.addEventListener("hidden.bs.offcanvas", () => {
    const target = variableTarget;
    variableTarget = null;
    if (target?.isConnected) requestAnimationFrame(() => target.focus());
  });
  document.getElementById("restore-content-form")?.addEventListener("submit", () => { dirty = false; });
  window.addEventListener("beforeunload", event => { if (dirty) { event.preventDefault(); event.returnValue = ""; } });
  save.onclick = async () => {
    if (busy) return;
    showError("");
    if (!validateFields()) return;
    read();
    busy = true;
    const sendInterval = !interval?.value ? null : interval.valueAsNumber;
    window.adminForms.setBusy(root, true);
    try {
      const result = await request(root.dataset.save, input.id ? "PATCH" : "POST", { [root.dataset.payloadKey || "reply_content"]: { ...input, enabled: enabled?.checked, scope: scope?.value || input.scope, send_interval: sendInterval, name: reply.name, messages: reply.messages } });
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
