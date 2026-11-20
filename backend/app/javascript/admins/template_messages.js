document.addEventListener("DOMContentLoaded", () => {
  const root = document.querySelector("[data-template-editor]"); if (!root) return;
  const templates = JSON.parse(root.dataset.templates), events = JSON.parse(root.dataset.events), bindings = JSON.parse(root.dataset.bindings);
  const feedback = root.querySelector("[data-template-feedback]");
  let revision = root.dataset.revision;
  root.querySelectorAll("[data-template-event]").forEach(section => {
    const event = section.dataset.templateEvent, definition = events[event], choice = section.querySelector("[data-template-choice]");
    const fields = section.querySelector("[data-template-fields]"), preview = section.querySelector("[data-template-preview]");
    let mapping = {};
    function enhance(select) { if (window.TomSelect) new window.TomSelect(select, { create: false, controlInput: null, dropdownParent: "body" }); }
    function draw() {
      const template = templates.find(t => t.template_id === choice.value); fields.replaceChildren(); mapping = {};
      const matches = [...(template?.content || "").matchAll(/([^\n{}]*)\{\{\s*(\w+)\.DATA\s*\}\}/g)];
      matches.forEach(([, rawLabel, key]) => {
        const label = rawLabel.trim().replace(/[:：]$/, "") || key;
        const wrap = document.createElement("div"); wrap.className = "mb-3";
        const title = document.createElement("label"); title.className = "form-label"; title.textContent = label + " · " + key;
        const select = document.createElement("select"); select.className = "form-select"; select.id = "field-" + event + "-" + key; title.htmlFor = select.id;
        Object.entries(definition.fields).forEach(([value, spec]) => select.add(new Option(spec.label, value)));
        const previous = bindings[event]?.template_id === choice.value ? bindings[event].mapping[key] : null;
        const matched = Object.entries(definition.fields).find(([, spec]) => label.includes(spec.label) || spec.label.includes(label));
        const timed = /^(time|date)\d*$/.test(key) ? Object.entries(definition.fields).find(([, spec]) => spec.type === "time") : null;
        select.value = previous || matched?.[0] || timed?.[0] || Object.keys(definition.fields)[0]; mapping[key] = select.value;
        select.onchange = () => { mapping[key] = select.value; showPreview(); }; wrap.append(title, select); fields.append(wrap); enhance(select);
      }); showPreview();
    }
    function showPreview() {
      preview.textContent = (templates.find(t => t.template_id === choice.value)?.content || "选择模板后预览字段")
        .replace(/\{\{\s*(\w+)\.DATA\s*\}\}/g, (_, key) => definition.fields[mapping[key]]?.example || ""); preview.style.whiteSpace = "pre-wrap";
    }
    choice.onchange = draw; enhance(choice); draw();
    section.querySelector("[data-template-save]").onclick = async (e) => {
      e.target.disabled = true; feedback.hidden = true;
      try {
        const response = await fetch(root.dataset.url, { method: "PATCH", headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" }, body: JSON.stringify({ template_binding: { event, template_id: choice.value, mapping, revision } }) });
        const result = await response.json(); if (!response.ok) throw new Error(result.error || "绑定未保存"); revision = result.revision;
        feedback.className = "alert alert-success"; feedback.textContent = "绑定已保存，同类事件将复用此配置。";
      } catch (error) { feedback.className = "alert alert-danger"; feedback.textContent = error.message; }
      finally { feedback.hidden = false; e.target.disabled = false; }
    };
  });
});
