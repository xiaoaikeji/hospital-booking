(() => {
  const upload = document.querySelector("#release-upload");
  let loading = 0;
  let templates = [];
  async function refreshTemplates() {
    const sequence = ++loading;
    const status = upload.querySelector("[role=status]");
    const list = upload.querySelector("#upload-template");
    status.textContent = "正在读取微信模板…";
    try {
      const res = await fetch(upload.dataset.templates);
      if (!res.ok) throw Error();
      const data = await res.json();
      if (sequence !== loading) return;
      templates = data.templates;
      const options = templates.map(row => {
        const option = new Option(`#${row.template_id} · ${row.user_version} · ${row.user_desc || ""}`, row.template_id);
        return option;
      });
      list.tomselect?.clear(true);
      list.tomselect?.clearOptions();
      list.replaceChildren(new Option("请选择模板", ""), ...options);
      list.tomselect?.sync();
      list.tomselect?.refreshOptions(false);
      status.textContent = data.error || (options.length ? "" : "微信模板库为空，请先将草稿加入库。");
    } catch { if (sequence === loading) status.textContent = "读取失败，可手工填写模板资料。"; }
  }
  if (upload) {
    const form = upload.querySelector("form");
    const app = upload.querySelector("#upload-app");
    const selectApp = () => { form.action = app.value; };
    selectApp();
    app.addEventListener("change", selectApp);
    upload.addEventListener("show.bs.modal", refreshTemplates);
    upload.querySelector("[data-refresh-templates]").addEventListener("click", refreshTemplates);
    upload.querySelector("#upload-template").addEventListener("change", event => {
      const row = templates.find(item => String(item.template_id) === event.target.value);
      if (!row) return;
      form.elements["release[template_id]"].value = row.template_id;
      const type = form.elements["release[template_type]"];
      type.value = Number(row.template_type) === 1 ? "standard" : "normal";
      type.tomselect?.setValue(type.value, true);
      form.elements["release[version]"].value = row.user_version || "";
      form.elements["release[description]"].value = row.user_desc || "";
    });
    if (upload.dataset.open === "true") {
      document.addEventListener("DOMContentLoaded", () => window.tabler.Modal.getOrCreateInstance(upload).show(), {once: true});
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
  dialog?.addEventListener("hide.bs.modal", () => { dialogLoad++; });
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
      if (res.ok) body.innerHTML = content;
      else body.textContent = res.status === 409 ? content : "读取失败，请关闭后重试。";
    } catch { if (id === dialogLoad) body.textContent = "读取失败，请关闭后重试。"; }
  });
  const list = document.querySelector("#release-list");
  let polling = false;
  const paused = () => document.hidden || document.querySelector(".modal.show, [data-busy], form[aria-busy=true], #release-list details[open]");
  if (list) setInterval(async () => {
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
  }, 15000);

  document.addEventListener("submit", async event => {
    generation++;
    const form = event.target.closest("form[data-release-form]");
    if (!form) {
      if (!event.defaultPrevented) event.target.setAttribute("aria-busy", "true");
      return;
    }
    event.preventDefault();
    if (form.dataset.busy) return;
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
      if (!res.ok && !data.reconcile) { alert.textContent = data.error; return; }
      const target = new URL(location.href);
      target.searchParams.delete("upload");
      location.replace(target);
    } catch { alert.textContent = "请求结果未确认，请刷新并核实本地记录。"; }
    finally {
      delete form.dataset.busy;
      if (submit) submit.disabled = false;
      submit?.querySelector(".spinner-border")?.classList.add("d-none");
      submit?.querySelector("[data-admin-submit-icon]")?.classList.remove("d-none");
    }
  });
})();
