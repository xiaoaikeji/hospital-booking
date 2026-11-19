const linkForm = document.getElementById("official-link-create");
const confirmation = document.getElementById("official-link-confirm");
if (linkForm && confirmation) {
  confirmation.addEventListener("show.bs.modal", event => {
    const target = linkForm.elements.mini_program_id;
    if (!target.value) {
      event.preventDefault();
      if (target.tomselect) target.tomselect.focus();
      else target.reportValidity();
      return;
    }
    const notify = linkForm.querySelector("[type=checkbox][name=notify_users]").checked;
    const profile = linkForm.querySelector("[type=checkbox][name=show_profile]").checked;
    confirmation.querySelector("#official-link-confirm-description").textContent =
      "目标 " + target.selectedOptions[0].text + "。" + (notify ? "通知公众号粉丝。" : "关闭粉丝通知。") +
      (profile ? "展示在公众号主页。" : "隐藏主页展示。") + "发出后由微信管理员确认。";
  });
}
