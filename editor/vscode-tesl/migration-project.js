"use strict";

const fs = require("fs");
const path = require("path");

function inside(root, file) {
  const relative = path.relative(root, file);
  return relative === "" || relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

// Read only the documented flat manifest's entrypoint. This is application
// discovery, not permission to apply source; the compiler checks the selection.
function manifestEntry(source) {
  let section = "", entry;
  for (const line of source.split(/\r?\n/)) {
    const heading = line.trim().match(/^\[([\w-]+)\]\s*(?:#.*)?$/);
    if (heading) { section = heading[1]; continue; }
    if (line.trim().startsWith("[")) { section = ""; continue; }
    if (section !== "project") continue;
    const setting = line.match(/^\s*entrypoint\s*=\s*(.*?)\s*$/);
    if (!setting) continue;
    if (entry !== undefined) throw new Error("tesl.toml has duplicate project.entrypoint values.");
    const quoted = setting[1].match(/^("(?:[^"\\]|\\.)*")\s*(?:#.*)?$/);
    if (quoted) {
      try { entry = JSON.parse(quoted[1]); }
      catch (_) { throw new Error("Cannot read project.entrypoint in tesl.toml; select an application explicitly."); }
    } else {
      entry = setting[1].split("#")[0].trim();
      if (!entry || /[\[\]{}'"\r\n]/.test(entry)) throw new Error("Invalid project.entrypoint in tesl.toml.");
    }
  }
  return entry;
}

function projectForFile(file, workspaceRoot, readSource = (file) => fs.readFileSync(file, "utf8")) {
  if (!path.isAbsolute(file) || !inside(workspaceRoot, file)) throw new Error("Select a file inside an open workspace folder.");
  for (let directory = path.dirname(file); inside(workspaceRoot, directory); directory = path.dirname(directory)) {
    const manifest = path.join(directory, "tesl.toml");
    if (fs.existsSync(manifest)) {
      const configured = manifestEntry(readSource(manifest));
      const entry = configured ? path.resolve(directory, configured) : undefined;
      if (entry && (!inside(directory, entry) || path.extname(entry) !== ".tesl")) throw new Error("project.entrypoint must name a .tesl application inside its project.");
      return { projectRoot: directory, entry };
    }
    if (directory === workspaceRoot) break;
  }
  return { projectRoot: workspaceRoot };
}

module.exports = { projectForFile, manifestEntry };
