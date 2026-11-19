document.addEventListener("DOMContentLoaded", () => {
  const modal = document.getElementById("category-modal");
  if (!modal) return;
  const tree = JSON.parse(modal.dataset.tree);
  const form = modal.querySelector("form");
  const first = form.elements.first;
  const second = form.elements.second;
  const plans = modal.querySelector("[data-plans]");
  const files = modal.querySelector("[data-files]");
  const alert = modal.querySelector("[role=alert]");
  let node;

  function renderFiles(items) {
    files.replaceChildren();
    items.forEach((item, index) => {
      const field = modal.querySelector("template").content.firstElementChild.cloneNode(true);
      field.querySelector("legend").textContent = item.name;
      const upload = field.querySelector("[type=file]");
      upload.name = "certificates[" + index + "]";
      upload.setAttribute("aria-label", item.name);
      const sample = field.querySelector("a");
      if (item.url) { sample.href = item.url; sample.hidden = false; }
      const permanent = field.querySelector("[type=checkbox]");
      permanent.name = "expire_modes[" + index + "]";
      const expiry = field.querySelector("[data-expiry]");
      const date = expiry.querySelector("input");
      date.id = "category-expiry-" + index;
      date.name = "expire_times[" + index + "]";
      expiry.querySelector("label").htmlFor = date.id;
      permanent.addEventListener("change", () => {
        expiry.hidden = date.disabled = permanent.checked;
      });
      files.append(field);
    });
  }

  function selectSecond() {
    const parent = tree.find((entry) => String(entry.id) === first.value);
    node = parent?.children.find((entry) => String(entry.id) === second.value);
    const choices = node?.plans || [];
    plans.hidden = choices.length <= 1;
    const group = plans.querySelector("div");
    group.replaceChildren();
    if (choices.length > 1) choices.forEach((items, index) => {
      const label = document.createElement("label");
      label.className = "form-check";
      const input = document.createElement("input");
      input.type = "radio"; input.className = "form-check-input"; input.name = "plan";
      input.required = true; input.value = index;
      input.addEventListener("change", () => renderFiles(items));
      label.append(input, document.createTextNode(items.map((item) => item.name).join("、")));
      group.append(label);
    });
    const remark = modal.querySelector("[data-remark]");
    remark.textContent = node?.remark || "";
    remark.hidden = !remark.textContent;
    modal.querySelector("[data-urgent]").hidden = choices.length === 0;
    modal.querySelector("[data-urgent] [type=checkbox]").checked = false;
    renderFiles(choices.length === 1 ? choices[0] : []);
  }

  first.addEventListener("change", () => {
    const children = tree.find((entry) => String(entry.id) === first.value)?.children || [];
    const options = children.map((entry) => ({ value: String(entry.id), text: entry.name }));
    if (second.tomselect) {
      second.tomselect.clear(true);
      second.tomselect.clearOptions();
      second.tomselect.addOptions(options);
      second.tomselect.refreshOptions(false);
      children.length ? second.tomselect.enable() : second.tomselect.disable();
    } else {
      second.replaceChildren(new Option("请选择", ""), ...options.map((entry) => new Option(entry.text, entry.value)));
      second.disabled = !children.length;
    }
    selectSecond();
  });
  second.addEventListener("change", selectSecond);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("[type=submit]");
    if (button.disabled) return;
    button.disabled = true;
    button.querySelector(".spinner-border").classList.remove("d-none");
    alert.hidden = true;
    try {
      const response = await fetch(form.action, { method: "POST", body: new FormData(form), credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || "" } });
      const body = await response.json();
      alert.querySelector("a").hidden = !body.verify;
      if (!response.ok) throw new Error(body.error || "请核实微信当前类目后再试");
      window.location.assign(body.url);
    } catch (error) {
      alert.querySelector("span").textContent = error.message;
      alert.hidden = false;
      alert.scrollIntoView({ block: "center" });
    } finally {
      button.disabled = false;
      button.querySelector(".spinner-border").classList.add("d-none");
    }
  });
});
