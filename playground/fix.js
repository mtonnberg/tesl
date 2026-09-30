function applyFix(source, fix) {
  if (fix.kind === "multi") {
    const key = f => f.kind === "replace_range"
      ? [f.start_line, f.start_col]
      : [f.line !== undefined ? f.line : f.start_line, 0];
    const sorted = fix.edits.slice().sort((a, b) => {
      const ka = key(a), kb = key(b);
      return kb[0] - ka[0] || kb[1] - ka[1];
    });
    return sorted.reduce((s, e) => applyFix(s, e), source);
  }
  const lines = source.split("\n");
  switch (fix.kind) {
    case "replace_line":
      lines[fix.line] = fix.replacement;
      return lines.join("\n");
    case "insert_line":
      lines.splice(fix.line, 0, fix.text);
      return lines.join("\n");
    case "replace_span": {
      const n = fix.end_line - fix.start_line + 1;
      if (fix.replacement === "") lines.splice(fix.start_line, n);
      else lines.splice(fix.start_line, n, fix.replacement);
      return lines.join("\n");
    }
    case "replace_range": {
      const s = lines[fix.start_line], e = lines[fix.end_line];
      const joined = s.slice(0, fix.start_col) + fix.replacement + e.slice(fix.end_col);
      lines.splice(fix.start_line, fix.end_line - fix.start_line + 1, joined);
      return lines.join("\n");
    }
    default:
      return source;
  }
}


window.TeslApplyFix = applyFix;
