window.NotificationVariables = {
  render(text, fields, examples) {
    const pattern = /(?<!\{)\{([A-Za-z_]\w*)\}(?!\})/g;
    const lines = String(text || "").replace(/\r\n/g, "\n").split("\n").filter(line => {
      return ![...line.matchAll(pattern)].some(([, key]) => fields[key]?.optional && String(examples[key] ?? "").trim() === "");
    });
    return lines.join("\n").replace(pattern, (token, key) => Object.hasOwn(examples, key) ? String(examples[key] ?? "") : token).replace(/\{\{([A-Za-z_]\w*)\}\}/g, "{$1}");
  }
};
