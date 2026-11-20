(() => {
  const upload = document.querySelector("#release-upload[data-templates]");
  if (upload) {
    const form = upload.querySelector("form");
    const app = form.querySelector("#upload-app");
    const list = form.querySelector("#upload-template");
    const status = form.querySelector("[role=status]");
    const fields = form.querySelector("[data-template-fields]");
    const templateId = form.elements["release[template_id]"];
    const version = form.elements["release[version]"];
    const description = form.elements["release[description]"];
    const type = form.elements["release[template_type]"];
    const typeValue = document.createElement("input");
    typeValue.type = "hidden";
    typeValue.name = type.name;
    form.append(typeValue);
    const submit = form.querySelector("[type=submit]");
    let rows = [], manual = false, loading = false;

    function updateControls() {
      const row = rows.find(item => String(item.template_id) === list.value);
      fields.hidden = !row && !manual;
      templateId.readOnly = !manual;
      version.readOnly = !manual && Boolean(row?.user_version);
      description.readOnly = !manual && Boolean(row?.user_desc);
      typeValue.value = type.value;
      typeValue.disabled = manual;
      type.disabled = !manual;
      if (manual) type.tomselect?.enable();
      else type.tomselect?.disable();
      list.required = !manual;
      submit.disabled = loading || fields.hidden || !app.value;
      if (app.value) form.action = app.value;
    }
    function fillSelection() {
      const row = rows.find(item => String(item.template_id) === list.value);
      templateId.value = row?.template_id || "";
      type.value = Number(row?.template_type) === 1 ? "standard" : "normal";
      type.tomselect?.setValue(type.value, true);
      version.value = row?.user_version || "";
      description.value = row?.user_desc || "";
      updateControls();
    }

    async function refreshTemplates() {
      if (loading) return;
      loading = true;
      submit.disabled = true;
      status.textContent = "正在读取微信模板…";
      try {
        const res = await fetch(upload.dataset.templates);
        if (!res.ok || res.redirected) throw Error();
        const data = await res.json();
        const previousId = templateId.value || list.value;
        rows = data.templates;
        manual = Boolean(data.error);
        const options = rows.map(row => new Option(`#${row.template_id} · ${row.user_version || ""} · ${row.user_desc || ""}`, row.template_id));
        list.tomselect?.clear(true);
        list.tomselect?.clearOptions();
        list.replaceChildren(new Option(manual ? "选择缓存模板或手工填写" : "请选择模板", ""), ...options);
        list.tomselect?.sync();
        const available = rows.some(row => String(row.template_id) === previousId);
        list.value = available ? previousId : "";
        list.tomselect?.setValue(list.value, true);
        if (!manual) fillSelection();
        status.textContent = data.error || (previousId && !available ? "所选模板已从微信模板库移除，请重新选择。" : rows.length ? "" : "微信模板库为空，请先将草稿加入库。");
      } catch {
        manual = true;
        status.textContent = "读取微信模板失败，可手工填写模板资料。";
      } finally {
        loading = false;
        updateControls();
      }
    }
    updateControls();
    app.addEventListener("change", updateControls);
    list.addEventListener("change", fillSelection);
    upload.querySelector("[data-refresh-templates]").addEventListener("click", refreshTemplates);
    upload.addEventListener("show.bs.modal", refreshTemplates);
    if (upload.dataset.destination) refreshTemplates();
    if (upload.dataset.open === "true") {
      document.addEventListener("DOMContentLoaded", () => window.tabler.Modal.getOrCreateInstance(upload).show(), { once: true });
    }
  }

  async function loadImage(box) {
    const msg = box.querySelector("[role=status]"), retry = box.querySelector("button");
    retry.hidden = true;
    try {
      const res = await fetch(box.dataset.screenshot);
      if (!res.ok) throw Error(res.status === 503 ? await res.text() : "读取失败，请重试。");
      if (!res.headers.get("Content-Type")?.startsWith("image/")) throw Error("读取失败，请重新登录后重试。");
      const url = URL.createObjectURL(await res.blob());
      const preview = box.querySelector("template").content.cloneNode(true);
      preview.querySelectorAll("img").forEach(img => img.src = url);
      box.append(preview);
      msg.textContent = "";
    } catch (e) { msg.textContent = e.message; retry.hidden = false; }
  }
  document.querySelectorAll("[data-screenshot]").forEach(box => {
    loadImage(box);
    box.querySelector("button").addEventListener("click", () => loadImage(box));
  });
  const dialog = document.querySelector("#release-dialog");
  let generation = 0;
  let dialogLoad = 0;
  document.addEventListener("show.bs.modal", () => { generation++; });
  document.addEventListener("visibilitychange", () => { generation++; });
  dialog?.addEventListener("hide.bs.modal", () => {
    dialogLoad++;
    dialog.querySelectorAll("select[data-enhanced-select]").forEach(select => select.tomselect?.destroy());
  });
  document.addEventListener("click", async event => {
    const opener = event.target.closest("[data-release-dialog]");
    if (!opener || !dialog) return;
    const id = ++dialogLoad;
    const body = dialog.querySelector(".modal-body");
    dialog.querySelector("h2").textContent = opener.textContent;
    body.textContent = "正在读取…";
    window.tabler.Modal.getOrCreateInstance(dialog).show();
    try {
      const res = await fetch(opener.dataset.releaseDialog);
      if (res.redirected) throw Error();
      const content = await res.text();
      if (id !== dialogLoad) return;
      if (res.ok) {
        body.innerHTML = content;
        window.initializeAdminSelects?.(body);
      } else body.textContent = res.status === 409 ? content : "读取失败，请关闭后重试。";
    } catch { if (id === dialogLoad) body.textContent = "读取失败，请关闭后重试。"; }
  });
  const list = document.querySelector("#release-list");
  let polling = false;
  const paused = () => document.hidden || document.querySelector(".modal.show, [data-busy], form[aria-busy=true], #release-list details[open]");
  async function refreshList() {
    if (polling || paused()) return;
    const id = generation;
    polling = true;
    try {
      const res = await fetch(list.dataset.source);
      if (!res.ok || res.redirected) return;
      const html = await res.text();
      if (id === generation && !paused()) list.innerHTML = html;
    } catch { /* 保留最近成功显示的列表。 */ }
    finally { polling = false; }
  }
  if (list) setInterval(refreshList, 15000);
  document.addEventListener("hide.bs.modal", event => {
    if (event.target.querySelector("form[data-busy]")) event.preventDefault();
  });
  let refreshOnClose = false;
  document.addEventListener("hidden.bs.modal", () => {
    if (!refreshOnClose) return;
    refreshOnClose = false;
    if (list) refreshList();
    else location.reload();
  });

  document.addEventListener("submit", async event => {
    generation++;
    const form = event.target.closest("form[data-release-form]");
    if (!form) {
      if (!event.defaultPrevented) event.target.setAttribute("aria-busy", "true");
      return;
    }
    event.preventDefault();
    if (form.dataset.busy || form.dataset.uncertain) return;
    form.dataset.busy = "1";
    const submit = form.querySelector("[type=submit]");
    if (submit) submit.disabled = true;
    submit?.querySelector(".spinner-border")?.classList.remove("d-none");
    submit?.querySelector("[data-admin-submit-icon]")?.classList.add("d-none");
    const alert = form.querySelector("[role=alert]");
    try {
      const res = await fetch(form.action, {method:"POST", body:new FormData(form), headers:{Accept:"application/json"}});
      const data = await res.json();
      if (data.expected_round && form.elements.expected_round) form.elements.expected_round.value = data.expected_round;
      if (!res.ok) refreshOnClose = true;
      if (!res.ok && !data.reconcile) { alert.textContent = data.error; return; }
      const target = new URL(upload?.contains(form) && upload.dataset.destination || location.href, location.href);
      target.searchParams.delete("upload");
      location.replace(target);
    } catch {
      alert.textContent = "请求结果未确认，请关闭并核实本地记录。";
      form.dataset.uncertain = "1";
      refreshOnClose = true;
    }
    finally {
      delete form.dataset.busy;
      if (submit) submit.disabled = Boolean(form.dataset.uncertain);
      submit?.querySelector(".spinner-border")?.classList.add("d-none");
      submit?.querySelector("[data-admin-submit-icon]")?.classList.remove("d-none");
    }
  });
})();
