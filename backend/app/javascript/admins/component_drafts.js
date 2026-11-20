document.addEventListener("DOMContentLoaded", () => {
  const composer = document.querySelector("[data-draft-message-composer]");
  const keywordOrder = document.querySelector("[data-draft-keyword-order]");
  const jobMonitor = document.querySelector("[data-draft-job-monitor]");
  if (composer) previewMessageComposer(composer);
  if (keywordOrder) previewKeywordOrder(keywordOrder);
  if (jobMonitor) previewJobMonitor(jobMonitor);
});

function previewMessageComposer(composer) {
  const fields = JSON.parse(composer.dataset.fields);
  const examples = JSON.parse(composer.dataset.examples);
  const preview = composer.querySelectorAll("[data-draft-message-preview]");
  const drawer = composer.querySelector("#draft-variable-drawer");
  let activeTextarea;

  composer.querySelectorAll("[data-draft-message] textarea").forEach((textarea, index) => {
    textarea.addEventListener("input", () => {
      const text = window.NotificationVariables.render(textarea.value, fields, examples);
      preview[index].textContent = text || "请输入文字内容";
    });
  });

  composer.addEventListener("click", event => {
    const opener = event.target.closest("[data-draft-variable-opener]");
    if (opener) {
      activeTextarea = opener.closest("[data-draft-message]").querySelector("textarea");
      return;
    }

    const variable = event.target.closest("[data-draft-variable]");
    if (!variable || !activeTextarea) return;
    const token = `{${variable.dataset.draftVariable}}`;
    activeTextarea.setRangeText(token, activeTextarea.selectionStart, activeTextarea.selectionEnd, "end");
    activeTextarea.dispatchEvent(new Event("input", { bubbles: true }));
  });

  drawer.addEventListener("hidden.bs.offcanvas", () => {
    const textarea = activeTextarea;
    activeTextarea = null;
    if (textarea) requestAnimationFrame(() => textarea.focus());
  });
}

function previewKeywordOrder(root) {
  const list = root.querySelector("[data-draft-keyword-list]");
  const example = root.querySelector("[data-draft-rule-example]");
  let dragged;

  function updateOrder() {
    const rules = [...list.children];
    rules.forEach((rule, index) => {
      rule.querySelector("[data-draft-rule-position]").textContent = index + 1;
      rule.querySelector('[data-draft-rule-move="up"]').disabled = index === 0;
      rule.querySelector('[data-draft-rule-move="down"]').disabled = index === rules.length - 1;
    });
    const text = "取消预约";
    const match = rules.find(({ dataset }) => {
      return dataset.match === "contain" ? text.includes(dataset.keyword) : text === dataset.keyword;
    });
    example.textContent = `输入「${text}」会回复「${match.dataset.reply}」。`;
  }

  list.addEventListener("click", event => {
    const button = event.target.closest("[data-draft-rule-move]");
    if (!button) return;
    const rule = button.closest("[data-draft-rule]");
    if (button.dataset.draftRuleMove === "up") {
      rule.previousElementSibling?.before(rule);
    } else {
      rule.nextElementSibling?.after(rule);
    }
    updateOrder();
    (button.disabled ? rule.querySelector("button:not([disabled])") : button)?.focus();
  });

  list.addEventListener("dragstart", event => {
    const handle = event.target.closest("[data-draft-rule-grip]");
    if (!handle) return;
    dragged = handle.closest("[data-draft-rule]");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", dragged.dataset.keyword);
  });
  list.addEventListener("dragover", event => {
    if (!dragged) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
  });
  list.addEventListener("drop", event => {
    const target = event.target.closest("[data-draft-rule]");
    if (!dragged || !target || target === dragged) return;
    event.preventDefault();
    const { top, height } = target.getBoundingClientRect();
    if (event.clientY < top + height / 2) target.before(dragged);
    else target.after(dragged);
    dragged = null;
    updateOrder();
  });
  list.addEventListener("dragend", () => { dragged = null; });
}

function previewJobMonitor(root) {
  const range = root.querySelector("[data-draft-job-range]");
  const details = root.querySelector("[data-draft-job-detail]");

  root.addEventListener("click", event => {
    const slot = event.target.closest("[data-draft-job-slot]");
    if (!slot) return;
    root.querySelector('[data-draft-job-slot][aria-pressed="true"]')?.setAttribute("aria-pressed", "false");
    slot.setAttribute("aria-pressed", "true");
    range.textContent = slot.dataset.range;
    const record = document.getElementById(slot.dataset.detailId);
    details.replaceChildren(record ? record.content.cloneNode(true) : (
      slot.dataset.state === "missing" ? "这一小时没有执行记录。" : "这一小时没有失败记录。"
    ));
  });
}
