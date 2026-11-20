document.addEventListener("DOMContentLoaded", () => {
  const editor = document.getElementById("official-menu-editor");
  if (!editor) return;
  const el = (id) => document.getElementById("menu-" + id);
  const buttons = JSON.parse(editor.dataset.buttons);
  const editable = editor.dataset.editable === "true";
  const original = buttons.flatMap((n) => [n, ...(n.sub_button || [])]);
  const replyGroups = JSON.parse(editor.dataset.replies || "{}");
  const replyNames = Object.fromEntries(Object.entries(replyGroups).map(([id, r]) => ["reply_" + id, r.name]));
  original.filter(n => n.type === "click").forEach(n => { if (!replyNames[n.key]) replyNames[n.key] = "已有回复 · " + n.key; });
  const replies = Object.keys(replyNames);
  let replyPopup, replyNode;
  const types = { view: "跳转网页", miniprogram: "跳转小程序", media_id: "发送素材", article_id: "已发表内容" };
  types.click = "回复内容";
  const mediaHints = {
    image: "JPG、PNG、BMP、GIF，最多 10 MB",
    voice: "MP3、AMR、WAV，最多 2 MB、60 秒",
    video: "MP4，最多 10 MB"
  };
  const images = new WeakMap();
  let top = 0,
    sub = null,
    dirty = false,
    preview = false,
    busy = false,
    uncertain = false,
    uploading = false;
  let page = 1,
    articleRequest = 0;
  let fieldError;
  const current = () => (sub === null ? buttons[top] : buttons[top]?.sub_button?.[sub]);
  const siblings = () => (sub === null ? buttons : buttons[top].sub_button);
  const modal = (id) => window.tabler.Modal.getOrCreateInstance(el(id));
  const feedback = (message = "") => {
    el("feedback").textContent = message;
    el("feedback").hidden = !message;
    if (message) el("feedback").scrollIntoView({ block: "nearest" });
  };
  function clearFieldError() {
    if (!fieldError) return;
    const { styled, control, message } = fieldError;
    styled.classList.remove("is-invalid");
    control.removeAttribute("aria-invalid");
    control.removeAttribute("aria-describedby");
    message.hidden = true;
    fieldError = null;
  }
  function showFieldError(id, text) {
    const input = el(id);
    const styled = input.tomselect?.wrapper || input;
    const control = input.tomselect?.focus_node || input;
    const message = el(id + "-error");
    styled.classList.add("is-invalid");
    control.setAttribute("aria-invalid", "true");
    control.setAttribute("aria-describedby", message.id);
    message.textContent = text;
    message.hidden = false;
    fieldError = { styled, control, message };
    control.focus();
  }
  function setHelp(id, text) {
    const trigger = el(id);
    const tooltip = window.tabler.Tooltip.getInstance(trigger);
    if (tooltip) {
      trigger.dataset.bsOriginalTitle = text;
      tooltip.setContent({ ".tooltip-inner": text });
    } else {
      trigger.title = text;
    }
  }
  function button(label, active, onClick) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label || "未命名";
    b.className = "btn btn-sm text-truncate " + (active ? "btn-primary" : "btn-outline-secondary");
    b.addEventListener("click", onClick);
    return b;
  }
  function changed() {
    dirty = true;
    feedback();
    clearFieldError();
  }
  function options(select, items, value) {
    select.tomselect?.destroy();
    select.replaceChildren(...Object.entries(items).map(([k, v]) => new Option(v, k)));
    select.value = value || "";
    enhance(select);
  }
  function enhance(select) {
    if (window.TomSelect && !select.tomselect) {
      new window.TomSelect(select, {
        create: false,
        allowEmptyOption: true,
        controlInput: select.id === "menu-appid" ? undefined : null,
        dropdownParent: "body"
      });
    }
  }
  function setValue(input, value) {
    if (!input.tomselect) {
      input.value = value || "";
      return;
    }
    if (value && !Object.hasOwn(input.tomselect.options, value)) input.tomselect.addOption({ value, text: value });
    input.tomselect.setValue(value || "", true);
  }
  function drawBar() {
    el("bar").replaceChildren(...buttons.map((n, i) => button(n.name, i === top, () => select(i, null))));
    const children = buttons[top]?.sub_button || [];
    el("children").replaceChildren(...children.map((n, i) => button(n.name, i === sub, () => select(top, i))));
    el("preview-result").textContent = preview ? describe(current()) : "";
  }
  function describe(n) {
    if (!n || n.sub_button) return "";
    if (n.legacy) return n.value || "微信原有菜单动作";
    if (n.type === "miniprogram") return [n.appid, n.pagepath].filter(Boolean).join(" · ");
    if (n.type === "click" && replyGroups[n.key?.replace(/^reply_/, "")]) return replyGroups[n.key.replace(/^reply_/, "")].messages.map(m => m.type === "text" ? m.content.text : "小程序卡片：" + m.content.title).join("\n");
    return n.url || n.label || n.key || n.media_id || n.article_id || "尚未填写";
  }
  function select(i, j) {
    top = i;
    sub = j;
    draw();
  }
  function draw() {
    clearFieldError();
    drawBar();
    const n = current();
    el("fields").hidden = !n || preview;
    el("empty").hidden = !!n && !preview;
    el("empty").textContent = preview
      ? "点击菜单查看动作。"
      : editable
        ? "暂无菜单，可从微信读取或新增一级菜单。"
        : "暂无本地菜单。";
    el("heading").textContent = preview ? "菜单预览" : "菜单信息";
    el("preview").querySelector("span").textContent = preview ? "结束预览" : "预览";
    if (editable) {
      el("add").hidden = buttons.length >= 3 || preview;
      el("submit").disabled = busy || uncertain || uploading || preview;
    }
    if (!n) return;
    el("name").value = n.name;
    setHelp("name-hint", sub === null ? "一级菜单最多 4 个汉字或 8 个字母。" : "子菜单最多 8 个汉字或 16 个字母。");
    const group = Array.isArray(n.sub_button);
    el("type-group").hidden = group;
    const choices = { ...types };
    if (n.legacy) choices[n.type] = "微信原有动作";
    if (n.type === "view" && n.url?.startsWith("https://mp.weixin.qq.com/mp/profile_ext"))
      choices.view = "跳转账号主页";
    options(el("type"), choices, n.type);
    editor.querySelectorAll("[data-panel]").forEach((p) => {
      const show = n.legacy ? ["legacy"] : [n.type, ...(["view", "miniprogram"].includes(n.type) ? ["url"] : [])];
      p.hidden = group || !show.includes(p.dataset.panel);
    });
    if (n.legacy)
      el("legacy").textContent =
        (n.value || n.type) + "。此动作由微信公众平台创建，整套重新发布前需明确替换或删除。";
    setValue(el("appid"), n.appid);
    el("page").value = n.pagepath || "";
    el("url").value = n.url || "";
    el("url-label").textContent = n.type === "miniprogram" ? "备用网址（选填）" : "网址";
    setValue(el("kind"), n.kind || "image");
    setHelp("media-hint", mediaHints[n.kind || "image"]);
    el("media-name").textContent = n.type === "media_id" ? n.label || n.media_id || "" : "";
    const source =
      images.get(n) ||
      (n.type === "media_id" && n.kind === "image" && n.media_id && editable
        ? editor.dataset.image + "?media_id=" + encodeURIComponent(n.media_id)
        : "");
    el("image").hidden = !source;
    if (source && source !== el("image").getAttribute("src")) el("image").src = source;
    if (!source) el("image").removeAttribute("src");
    el("article-name").textContent = n.label || n.article_id || "尚未选择";
    setValue(el("key"), n.key);
    if (editable) {
      el("add-child").hidden = sub !== null || n.sub_button?.length >= 5;
      const position = sub ?? top;
      el("move-up").disabled = position === 0;
      el("move-down").disabled = position === siblings().length - 1;
    }
  }
  function addChild() {
    const parent = buttons[top];
    if (!parent || sub !== null || parent.sub_button?.length >= 5) return;
    if (!parent.sub_button) buttons[top] = { name: parent.name, sub_button: [] };
    const list = buttons[top].sub_button;
    list.push({ name: "", type: "view" });
    changed();
    select(top, list.length - 1);
    el("name").focus();
  }
  function remove() {
    if (!current()) return;
    siblings().splice(sub ?? top, 1);
    if (sub !== null && !buttons[top].sub_button.length) buttons[top] = { name: buttons[top].name, type: "view" };
    changed();
    select(Math.max(0, Math.min(top, buttons.length - 1)), null);
  }
  function move(by) {
    const list = siblings(),
      i = sub ?? top,
      j = i + by;
    if (j < 0 || j >= list.length) return;
    [list[i], list[j]] = [list[j], list[i]];
    changed();
    select(sub === null ? j : top, sub === null ? null : j);
  }
  async function request(url, data) {
    const headers = {
      Accept: "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
    };
    const init = { method: data ? "POST" : "GET", headers };
    if (data instanceof FormData) init.body = data;
    else if (data) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(data);
    }
    const response = await fetch(url, init);
    const result = await response.json();
    if (!response.ok) throw Object.assign(new Error(result.error || "操作未完成，请核对后再试"), { result });
    return result;
  }
  function validate() {
    for (const [i, parent] of buttons.entries()) {
      for (const [j, n] of [[null, parent], ...(parent.sub_button || []).map((item, k) => [k, item])]) {
        let error, field;
        const width = Array.from(n.name.trim()).reduce((sum, ch) => sum + (ch.codePointAt(0) > 127 ? 2 : 1), 0);
        if (!width || width > (j === null ? 8 : 16)) {
          field = "name";
          error = "请核对菜单名称及长度";
        } else if (n.legacy) {
          error = "请明确替换或删除微信原有动作后再发布";
        } else if (n.type === "view" && !/^https?:\/\//i.test(n.url || "")) {
          field = "url";
          error = "请填写有效网址";
        } else if (n.type === "miniprogram" && !n.appid) {
          field = "appid";
          error = "请选择目标小程序";
        } else if (n.type === "miniprogram" && !n.pagepath?.trim()) {
          field = "page";
          error = "请填写页面路径";
        } else if (n.type === "click" && !n.key) {
          error = "请选择或新增回复内容";
        } else if (["media_id", "article_id"].includes(n.type) && !n[n.type]) {
          error = "请选择素材或已发表内容";
        }
        if (error) {
          select(i, j);
          if (field) {
            feedback();
            showFieldError(field, error);
          } else {
            feedback((n.name || "未命名菜单") + "：" + error);
          }
          return false;
        }
      }
    }
    return true;
  }
  async function publish() {
    if (busy || uncertain || uploading || !validate()) return;
    busy = true;
    draw();
    editor.inert = true;
    try {
      const res = await request(editor.dataset.publish, {
        buttons,
        revision: editor.dataset.revision,
        clear: !buttons.length
      });
      dirty = false;
      location.assign(res.redirect);
    } catch (e) {
      uncertain = !e.result || !!e.result.pending;
      if (e.result?.revision != null) {
        const revision = document.querySelector("#pull-menu-form input[name=revision]");
        if (revision) revision.value = e.result.revision;
      }
      feedback(uncertain ? "发布结果待核实，请先从微信读取当前菜单。" : e.message);
    } finally {
      editor.inert = false;
      busy = false;
      draw();
    }
  }
  async function upload() {
    const node = current(),
      file = el("upload").files[0];
    if (!file || !node || uploading) return;
    const kind = el("kind").value;
    const data = new FormData();
    data.append("file", file);
    data.append("kind", kind);
    uploading = true;
    draw();
    editor.inert = true;
    try {
      Object.assign(node, await request(editor.dataset.media, data));
      if (images.has(node)) URL.revokeObjectURL(images.get(node));
      if (kind === "image") images.set(node, URL.createObjectURL(file));
      else images.delete(node);
      changed();
    } catch (e) {
      feedback(e.message);
    } finally {
      uploading = false;
      editor.inert = false;
      el("upload").value = "";
      draw();
    }
  }
  async function articles(next) {
    const ticket = ++articleRequest;
    const rows = el("article-rows");
    rows.textContent = "正在读取已发表内容…";
    page = next;
    el("article-prev").disabled = true;
    el("article-next").disabled = true;
    try {
      const res = await request(editor.dataset.articles + "?page=" + next);
      if (ticket !== articleRequest) return;
      rows.replaceChildren(
        ...res.items.map((item) =>
          button(item.label, false, () => {
            Object.assign(current(), item);
            changed();
            modal("article-picker").hide();
            draw();
          })
        )
      );
      if (!res.items.length) rows.textContent = "暂无已发表内容";
      el("article-prev").disabled = next <= 1;
      el("article-next").disabled = next >= res.pages;
    } catch (e) {
      rows.replaceChildren(
        document.createTextNode(e.message + " "),
        button("重试", false, () => articles(next))
      );
    }
  }
  el("image").addEventListener("error", () => {
    el("image").hidden = true;
  });
  enhance(el("appid"));
  enhance(el("kind"));
  options(el("key"), replyNames, "");
  el("preview").onclick = () => {
    preview = !preview;
    draw();
  };
  if (editable) {
    el("new-reply").onclick = () => { replyNode = current(); replyPopup = window.open(editor.dataset.newReply, "booking-menu-reply-" + editor.dataset.appId, "width=1100,height=850"); };
    el("edit-reply").onclick = () => {
      const id = current()?.key?.replace(/^reply_/, ""); if (!replyGroups[id]) return;
      replyNode = current(); replyPopup = window.open(editor.dataset.editReplyBase + "/" + encodeURIComponent(id) + "/edit?inline=1", "booking-menu-reply-" + editor.dataset.appId, "width=1100,height=850");
    };
    window.addEventListener("message", event => {
      if (event.origin !== location.origin || event.source !== replyPopup || event.data.type !== "booking.reply.saved" || String(event.data.appId) !== editor.dataset.appId) return;
      replyNames[event.data.key] = event.data.name; replies.push(event.data.key);
      replyGroups[event.data.id] = { name: event.data.name, messages: event.data.messages || [] };
      options(el("key"), replyNames, event.data.key);
      if (replyNode) { replyNode.key = event.data.key; changed(); draw(); }
    });
    el("add").onclick = () => {
      if (buttons.length >= 3) return;
      buttons.push({ name: "", type: "view" });
      changed();
      select(buttons.length - 1, null);
      el("name").focus();
    };
    el("add-child").onclick = () => {
      if (current().sub_button || !describe(current()) || describe(current()) === "尚未填写") addChild();
      else modal("convert-confirm").show();
    };
    el("delete").onclick = () => modal("remove-confirm").show();
    el("move-up").onclick = () => move(-1);
    el("move-down").onclick = () => move(1);
    el("submit").onclick = () => {
      if (!validate()) return;
      modal(buttons.length ? "publish-confirm" : "clear-confirm").show();
    };
    for (const [id, action] of [
      ["publish", publish],
      ["clear", publish],
      ["remove", remove],
      ["convert", addChild]
    ]) {
      el(id + "-form").onsubmit = (event) => {
        event.preventDefault();
        action();
      };
    }
    editor.querySelectorAll("[data-field]").forEach((input) => {
      input.addEventListener(input.tagName === "SELECT" ? "change" : "input", () => {
        const node = current();
        if (!node) return;
        node[input.dataset.field] = input.value;
        changed();
        drawBar();
      });
    });
    el("type").onchange = () => {
      const n = current(),
        type = el("type").value;
      if (!n || type === n.type) return;
      const next = { name: n.name, type };
      if (type === "click") next.key = replies[0];
      if (type === "miniprogram") next.appid = el("appid").options[1]?.value || "";
      siblings()[sub ?? top] = next;
      changed();
      draw();
    };
    el("kind").onchange = () => {
      const node = current();
      if (!node || (node.kind || "image") === el("kind").value) return;
      delete node.media_id;
      delete node.proof;
      delete node.label;
      node.kind = el("kind").value;
      images.delete(node);
      changed();
      draw();
    };
    el("upload").onchange = upload;
    el("articles").onclick = () => {
      modal("article-picker").show();
      articles(1);
    };
    el("article-prev").onclick = () => articles(page - 1);
    el("article-next").onclick = () => articles(page + 1);
    document.getElementById("pull-menu-form").addEventListener("submit", () => {
      dirty = false;
    });
    window.addEventListener("beforeunload", (e) => {
      if (dirty) {
        e.preventDefault();
        e.returnValue = "";
      }
    });
  }
  draw();
});
