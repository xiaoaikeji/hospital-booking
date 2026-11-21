document.addEventListener("DOMContentLoaded", () => {
  const history = document.querySelector("[data-job-history]");
  if (!history) return;
  const range = history.querySelector("[data-job-history-range]");
  const failures = history.querySelector("#job-history-failures");
  const reset = history.querySelector("[data-job-history-reset]");
  const initialFailures = [...failures.childNodes];
  let selected;

  history.addEventListener("click", event => {
    const slot = event.target.closest("[data-job-slot]");
    if (!slot) return;
    selected?.setAttribute("aria-pressed", "false");
    selected = slot;
    selected.setAttribute("aria-pressed", "true");
    range.textContent = slot.dataset.jobRange;
    reset.classList.remove("d-none");
    const details = document.getElementById(slot.dataset.jobDetail);
    if (details) {
      failures.replaceChildren(details.content.cloneNode(true));
    } else {
      const message = document.createElement("p");
      message.className = "p-3 mb-0 text-secondary";
      message.textContent = slot.dataset.jobState === "missing" ? "这一小时没有执行记录。" : "这一小时没有失败记录。";
      failures.replaceChildren(message);
    }
  });

  reset.addEventListener("click", () => {
    selected?.setAttribute("aria-pressed", "false");
    selected?.focus();
    selected = null;
    range.textContent = "最近失败";
    failures.replaceChildren(...initialFailures);
    reset.classList.add("d-none");
  });
});
