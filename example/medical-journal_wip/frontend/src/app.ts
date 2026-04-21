/**
 * Medical Journal — Single-page application
 *
 * Vanilla TypeScript SPA using Zod-validated API calls.
 * Demonstrates end-to-end integration with the Tesl backend.
 */

import { createClient, ApiError, type MedicalJournalClient } from "./api-client.js";
import type {
  Patient,
  JournalEntry,
  Prescription,
  DomainEvent,
  LoginResponse,
} from "./schemas.js";

// ── Client ──────────────────────────────────────────────────────────────────

const api = createClient({ baseUrl: "" }); // same origin
let session: LoginResponse | null = null;

// ── Router ──────────────────────────────────────────────────────────────────

type Route =
  | { page: "login" }
  | { page: "patients" }
  | { page: "patient"; id: string }
  | { page: "newPatient" }
  | { page: "newEntry"; patientId: string }
  | { page: "newPrescription"; patientId: string };

function parseRoute(): Route {
  const hash = location.hash.slice(1) || "/login";
  if (hash === "/patients") return { page: "patients" };
  if (hash === "/patients/new") return { page: "newPatient" };
  const entryMatch = hash.match(/^\/patients\/([^/]+)\/entries\/new$/);
  if (entryMatch) return { page: "newEntry", patientId: entryMatch[1] };
  const rxMatch = hash.match(/^\/patients\/([^/]+)\/prescriptions\/new$/);
  if (rxMatch) return { page: "newPrescription", patientId: rxMatch[1] };
  const patMatch = hash.match(/^\/patients\/([^/]+)$/);
  if (patMatch) return { page: "patient", id: patMatch[1] };
  return { page: "login" };
}

function navigate(hash: string) {
  location.hash = hash;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

const $ = (sel: string) => document.querySelector(sel)!;

function h(tag: string, attrs: Record<string, string> = {}, ...children: (string | Node)[]) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k.startsWith("on")) {
      // skip — we wire events manually
    } else {
      el.setAttribute(k, v);
    }
  }
  for (const c of children) {
    el.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return el;
}

function statusBadge(status: string): HTMLElement {
  const cls =
    status === "ActivePatient" ? "badge-active" :
    status === "Discharged" ? "badge-discharged" : "badge-transferred";
  const label =
    status === "ActivePatient" ? "Active" : status;
  return h("span", { class: `badge ${cls}` }, label);
}

function severityBadge(sev: string): HTMLElement {
  const cls =
    sev === "Routine" ? "badge-routine" :
    sev === "Urgent" ? "badge-urgent" : "badge-critical";
  return h("span", { class: `badge ${cls}` }, sev);
}

function formatDate(millis: number): string {
  return new Date(millis).toLocaleDateString("en-US", {
    year: "numeric", month: "short", day: "numeric",
  });
}

function showError(container: HTMLElement, msg: string) {
  const alert = h("div", { class: "alert alert-error" }, msg);
  container.prepend(alert);
  setTimeout(() => alert.remove(), 5000);
}

function showSuccess(container: HTMLElement, msg: string) {
  const alert = h("div", { class: "alert alert-success" }, msg);
  container.prepend(alert);
  setTimeout(() => alert.remove(), 3000);
}

function proofBanner(text: string): HTMLElement {
  const el = document.createElement("div");
  el.className = "proof-banner";
  el.innerHTML = text;
  return el;
}

// ── Pages ───────────────────────────────────────────────────────────────────

function renderLogin(app: HTMLElement) {
  const card = h("div", { class: "card" },
    h("h2", {}, "Sign In"),
    h("p", { class: "text-muted mb-1" }, "Enter your provider email to access the medical journal system."),
  );

  const form = document.createElement("form");

  const emailGroup = h("div", { class: "form-group" },
    h("label", {}, "Email"),
  );
  const emailInput = h("input", { type: "email", placeholder: "dr.smith@hospital.org", required: "" }) as HTMLInputElement;
  emailGroup.append(emailInput);

  const passGroup = h("div", { class: "form-group" },
    h("label", {}, "Password"),
  );
  const passInput = h("input", { type: "password", placeholder: "password", required: "" }) as HTMLInputElement;
  passGroup.append(passInput);

  const btn = h("button", { type: "submit", class: "btn btn-primary" }, "Sign In");

  form.append(emailGroup, passGroup, btn);
  card.append(form);
  app.append(
    proofBanner("🔒 The backend requires <code>Authenticated session</code> proof for all patient operations — enforced at compile time."),
    card,
  );

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      session = await api.login({
        email: emailInput.value,
        password: passInput.value,
      });
      updateNav();
      navigate("/patients");
    } catch (err) {
      const msg = err instanceof ApiError ? `Login failed (${err.status})` : "Network error";
      showError(card, msg);
    }
  });
}

function renderPatientList(app: HTMLElement) {
  if (!session) { navigate("/login"); return; }

  const header = h("div", { style: "display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem" },
    h("h2", {}, "Patients"),
  );
  const addBtn = h("button", { class: "btn btn-primary" }, "+ New Patient");
  addBtn.addEventListener("click", () => navigate("/patients/new"));
  header.append(addBtn);

  const card = h("div", { class: "card" });
  app.append(header, card);

  // load
  (async () => {
    try {
      const patients = await api.listPatients();
      if (patients.length === 0) {
        card.append(h("div", { class: "empty-state" }, "No patients yet. Create one to get started."));
        return;
      }
      const table = document.createElement("table");
      const thead = h("thead", {},
        h("tr", {},
          h("th", {}, "MRN"),
          h("th", {}, "Name"),
          h("th", {}, "DOB"),
          h("th", {}, "Blood"),
          h("th", {}, "Status"),
        ),
      );
      const tbody = document.createElement("tbody");
      for (const p of patients) {
        const row = h("tr", {},
          h("td", {}, p.medicalRecordNumber),
          h("td", {}, `${p.firstName} ${p.lastName}`),
          h("td", {}, p.dateOfBirth),
          h("td", {}, p.bloodType),
          h("td", {}, statusBadge(p.status)),
        );
        row.addEventListener("click", () => navigate(`/patients/${p.id}`));
        tbody.append(row);
      }
      table.append(thead, tbody);
      card.append(table);
    } catch (err) {
      showError(card, "Failed to load patients");
    }
  })();
}

function renderNewPatient(app: HTMLElement) {
  if (!session) { navigate("/login"); return; }

  const card = h("div", { class: "card" },
    h("h2", {}, "Register New Patient"),
  );
  app.append(
    proofBanner("✅ The backend validates: <code>ValidPatientName</code> (non-empty, ≤200 chars) and <code>ValidDateOfBirth</code> (non-empty) — empty fields are rejected at the proof layer."),
    card,
  );

  const form = document.createElement("form");

  const fnInput = h("input", { required: "", placeholder: "Alice" }) as HTMLInputElement;
  const lnInput = h("input", { required: "", placeholder: "Johnson" }) as HTMLInputElement;
  const dobInput = h("input", { type: "date", required: "" }) as HTMLInputElement;
  const btInput = h("input", { placeholder: "O+" }) as HTMLInputElement;
  const alInput = h("input", { placeholder: "Penicillin, Latex" }) as HTMLInputElement;

  form.append(
    h("div", { class: "form-row" },
      h("div", { class: "form-group" }, h("label", {}, "First Name"), fnInput),
      h("div", { class: "form-group" }, h("label", {}, "Last Name"), lnInput),
    ),
    h("div", { class: "form-row" },
      h("div", { class: "form-group" }, h("label", {}, "Date of Birth"), dobInput),
      h("div", { class: "form-group" }, h("label", {}, "Blood Type"), btInput),
    ),
    h("div", { class: "form-group" }, h("label", {}, "Allergies"), alInput),
  );

  const actions = h("div", { class: "actions" });
  const submitBtn = h("button", { type: "submit", class: "btn btn-primary" }, "Register Patient");
  const cancelBtn = h("button", { type: "button", class: "btn btn-outline" }, "Cancel");
  cancelBtn.addEventListener("click", () => navigate("/patients"));
  actions.append(submitBtn, cancelBtn);
  form.append(actions);
  card.append(form);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      const patient = await api.createPatient({
        firstName: fnInput.value,
        lastName: lnInput.value,
        dateOfBirth: dobInput.value,
        bloodType: btInput.value,
        allergies: alInput.value,
      });
      navigate(`/patients/${patient.id}`);
    } catch (err) {
      const msg = err instanceof ApiError
        ? `Validation failed (${err.status}): ${err.body}`
        : "Network error";
      showError(card, msg);
    }
  });
}

async function renderPatientDetail(app: HTMLElement, patientId: string) {
  if (!session) { navigate("/login"); return; }

  const loading = h("div", { class: "card" }, h("p", { class: "text-muted" }, "Loading..."));
  app.append(loading);

  let patient: Patient;
  try {
    patient = await api.getPatient(patientId);
  } catch {
    app.innerHTML = "";
    app.append(h("div", { class: "alert alert-error" }, "Patient not found."));
    return;
  }
  loading.remove();

  // Header
  const back = h("a", { href: "#/patients", style: "font-size:0.85rem;color:var(--primary);text-decoration:none" }, "← Back to patients");
  const header = h("div", { class: "card" },
    back,
    h("h2", { style: "margin-top:0.5rem" }, `${patient.firstName} ${patient.lastName}`),
    h("p", { class: "text-muted" }, `MRN: ${patient.medicalRecordNumber} · DOB: ${patient.dateOfBirth} · Blood: ${patient.bloodType} · Allergies: ${patient.allergies}`),
    h("p", { style: "margin-top:0.3rem" }, statusBadge(patient.status)),
  );
  app.append(header);

  // Tabs
  const tabsEl = h("div", { class: "tabs" });
  const contentEl = h("div", {});
  const tabNames = ["Journal Entries", "Prescriptions", "Timeline"];
  const tabElements: HTMLElement[] = [];

  for (const [i, name] of tabNames.entries()) {
    const tab = h("div", { class: `tab ${i === 0 ? "active" : ""}` }, name);
    tab.addEventListener("click", () => {
      tabElements.forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");
      loadTabContent(i);
    });
    tabElements.push(tab);
    tabsEl.append(tab);
  }
  app.append(tabsEl, contentEl);

  async function loadTabContent(index: number) {
    contentEl.innerHTML = "";
    if (index === 0) await renderEntries(contentEl, patientId, patient);
    else if (index === 1) await renderPrescriptions(contentEl, patientId, patient);
    else await renderTimeline(contentEl, patientId);
  }

  loadTabContent(0);
}

async function renderEntries(container: HTMLElement, patientId: string, patient: Patient) {
  const isActive = patient.status === "ActivePatient";

  if (isActive) {
    const addBtn = h("button", { class: "btn btn-primary btn-small mb-1" }, "+ Add Entry");
    addBtn.addEventListener("click", () => navigate(`/patients/${patientId}/entries/new`));
    container.append(addBtn);
  } else {
    container.append(
      proofBanner(`⛔ Patient is <strong>${patient.status}</strong> — the backend's <code>PatientIsActive</code> proof prevents adding entries.`),
    );
  }

  try {
    const entries = await api.listJournalEntries(patientId);
    if (entries.length === 0) {
      container.append(h("div", { class: "empty-state" }, "No journal entries yet."));
      return;
    }
    for (const entry of entries) {
      const card = h("div", { class: "card" },
        h("div", { style: "display:flex;justify-content:space-between;align-items:center" },
          h("h3", {}, entry.title),
          severityBadge(entry.severity),
        ),
        h("p", { class: "text-muted", style: "font-size:0.8rem;margin-bottom:0.3rem" },
          `${entry.entryType} · ${formatDate(entry.createdAt)} · by ${entry.authorId}`),
        h("p", {}, entry.content),
      );
      container.append(card);
    }
  } catch {
    showError(container, "Failed to load entries");
  }
}

async function renderPrescriptions(container: HTMLElement, patientId: string, patient: Patient) {
  const isActive = patient.status === "ActivePatient";
  const isPhysician = session?.role === "Physician" || session?.role === "Specialist";

  if (isActive && isPhysician) {
    const addBtn = h("button", { class: "btn btn-primary btn-small mb-1" }, "+ Add Prescription");
    addBtn.addEventListener("click", () => navigate(`/patients/${patientId}/prescriptions/new`));
    container.append(addBtn);
  } else if (!isActive) {
    container.append(
      proofBanner(`⛔ Patient is <strong>${patient.status}</strong> — <code>PatientIsActive</code> proof blocks prescriptions.`),
    );
  } else {
    container.append(
      proofBanner(`⛔ Your role (<strong>${session?.role}</strong>) lacks <code>IsPhysician</code> proof — only Physicians and Specialists can prescribe.`),
    );
  }

  try {
    const prescriptions = await api.listPrescriptions(patientId);
    if (prescriptions.length === 0) {
      container.append(h("div", { class: "empty-state" }, "No prescriptions yet."));
      return;
    }
    const table = document.createElement("table");
    table.append(
      h("thead", {},
        h("tr", {},
          h("th", {}, "Medication"),
          h("th", {}, "Dosage"),
          h("th", {}, "Frequency"),
          h("th", {}, "Duration"),
          h("th", {}, "Status"),
          h("th", {}, "Date"),
        ),
      ),
    );
    const tbody = document.createElement("tbody");
    for (const rx of prescriptions) {
      tbody.append(
        h("tr", { style: "cursor:default" },
          h("td", {}, rx.medication),
          h("td", {}, rx.dosage),
          h("td", {}, rx.frequency),
          h("td", {}, `${rx.durationDays} days`),
          h("td", {}, h("span", { class: "badge badge-active" }, rx.status)),
          h("td", {}, formatDate(rx.createdAt)),
        ),
      );
    }
    table.append(tbody);
    container.append(h("div", { class: "card" }, table));
  } catch {
    showError(container, "Failed to load prescriptions");
  }
}

async function renderTimeline(container: HTMLElement, patientId: string) {
  container.append(
    proofBanner("📜 CQRS event store — every mutation records a <code>DomainEvent</code> alongside the projection update."),
  );

  try {
    const events = await api.getTimeline(patientId);
    if (events.length === 0) {
      container.append(h("div", { class: "empty-state" }, "No events recorded yet."));
      return;
    }
    for (const evt of events) {
      container.append(
        h("div", { class: "timeline-item" },
          h("div", { class: "timeline-dot" }),
          h("div", {},
            h("strong", {}, evt.eventType),
            h("p", {}, evt.summary),
            h("div", { class: "timeline-meta" }, `${evt.aggregateType} · ${formatDate(evt.createdAt)} · by ${evt.actorId}`),
          ),
        ),
      );
    }
  } catch {
    showError(container, "Failed to load timeline");
  }
}

function renderNewEntry(app: HTMLElement, patientId: string) {
  if (!session) { navigate("/login"); return; }

  const card = h("div", { class: "card" },
    h("h2", {}, "Add Journal Entry"),
  );
  app.append(
    proofBanner("✅ Validated proofs: <code>PatientIsActive</code> (patient not discharged/transferred), <code>ValidJournalTitle</code> (non-empty, ≤500 chars), <code>ValidJournalContent</code> (non-empty, ≤50k chars)."),
    card,
  );

  const form = document.createElement("form");

  const typeSelect = h("select", {}) as HTMLSelectElement;
  for (const t of ["Note", "Diagnosis", "LabResult", "Procedure"]) {
    typeSelect.append(h("option", { value: t }, t));
  }

  const sevSelect = h("select", {}) as HTMLSelectElement;
  for (const s of ["Routine", "Urgent", "Critical"]) {
    sevSelect.append(h("option", { value: s }, s));
  }

  const titleInput = h("input", { required: "", placeholder: "Annual checkup" }) as HTMLInputElement;
  const contentArea = h("textarea", { required: "", placeholder: "Patient presents with..." }) as HTMLTextAreaElement;

  form.append(
    h("div", { class: "form-row" },
      h("div", { class: "form-group" }, h("label", {}, "Entry Type"), typeSelect),
      h("div", { class: "form-group" }, h("label", {}, "Severity"), sevSelect),
    ),
    h("div", { class: "form-group" }, h("label", {}, "Title"), titleInput),
    h("div", { class: "form-group" }, h("label", {}, "Content"), contentArea),
  );

  const actions = h("div", { class: "actions" });
  const submitBtn = h("button", { type: "submit", class: "btn btn-primary" }, "Save Entry");
  const cancelBtn = h("button", { type: "button", class: "btn btn-outline" }, "Cancel");
  cancelBtn.addEventListener("click", () => navigate(`/patients/${patientId}`));
  actions.append(submitBtn, cancelBtn);
  form.append(actions);
  card.append(form);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await api.addJournalEntry(patientId, {
        entryType: typeSelect.value as any,
        title: titleInput.value,
        content: contentArea.value,
        severity: sevSelect.value as any,
      });
      navigate(`/patients/${patientId}`);
    } catch (err) {
      const msg = err instanceof ApiError
        ? `Rejected (${err.status}): ${err.body}`
        : "Network error";
      showError(card, msg);
    }
  });
}

function renderNewPrescription(app: HTMLElement, patientId: string) {
  if (!session) { navigate("/login"); return; }

  const card = h("div", { class: "card" },
    h("h2", {}, "Add Prescription"),
  );
  app.append(
    proofBanner("✅ Triple proof chain: <code>IsPhysician</code> (role check), <code>PatientIsActive</code> (status check), plus <code>ValidMedication</code> + <code>ValidDosage</code> + <code>ValidFrequency</code> + <code>ValidDuration</code> (1–365 days). Removing any check causes a <strong>compile error</strong>."),
    card,
  );

  const form = document.createElement("form");

  const medInput = h("input", { required: "", placeholder: "Lisinopril" }) as HTMLInputElement;
  const dosInput = h("input", { required: "", placeholder: "10mg" }) as HTMLInputElement;
  const freqInput = h("input", { required: "", placeholder: "once daily" }) as HTMLInputElement;
  const durInput = h("input", { type: "number", required: "", min: "1", max: "365", placeholder: "90" }) as HTMLInputElement;

  form.append(
    h("div", { class: "form-group" }, h("label", {}, "Medication"), medInput),
    h("div", { class: "form-row" },
      h("div", { class: "form-group" }, h("label", {}, "Dosage"), dosInput),
      h("div", { class: "form-group" }, h("label", {}, "Frequency"), freqInput),
      h("div", { class: "form-group" }, h("label", {}, "Duration (days)"), durInput),
    ),
  );

  const actions = h("div", { class: "actions" });
  const submitBtn = h("button", { type: "submit", class: "btn btn-primary" }, "Prescribe");
  const cancelBtn = h("button", { type: "button", class: "btn btn-outline" }, "Cancel");
  cancelBtn.addEventListener("click", () => navigate(`/patients/${patientId}`));
  actions.append(submitBtn, cancelBtn);
  form.append(actions);
  card.append(form);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await api.addPrescription(patientId, {
        medication: medInput.value,
        dosage: dosInput.value,
        frequency: freqInput.value,
        durationDays: parseInt(durInput.value, 10),
      });
      navigate(`/patients/${patientId}`);
    } catch (err) {
      const msg = err instanceof ApiError
        ? `Rejected (${err.status}): ${err.body}`
        : "Network error";
      showError(card, msg);
    }
  });
}

// ── Nav update ──────────────────────────────────────────────────────────────

function updateNav() {
  const navUser = $("#nav-user");
  if (session) {
    navUser.textContent = `${session.displayName} (${session.role})`;
    navUser.innerHTML += ` <a href="#" style="color:#bfdbfe;margin-left:0.5rem;font-size:0.8rem" id="logout-link">Logout</a>`;
    document.getElementById("logout-link")?.addEventListener("click", (e) => {
      e.preventDefault();
      session = null;
      api.logout();
      updateNav();
      navigate("/login");
    });
  } else {
    navUser.textContent = "";
  }
}

// ── Router dispatch ─────────────────────────────────────────────────────────

function render() {
  const app = $("#app") as HTMLElement;
  app.innerHTML = "";
  const route = parseRoute();

  switch (route.page) {
    case "login":         renderLogin(app); break;
    case "patients":      renderPatientList(app); break;
    case "newPatient":    renderNewPatient(app); break;
    case "patient":       renderPatientDetail(app, route.id); break;
    case "newEntry":      renderNewEntry(app, route.patientId); break;
    case "newPrescription": renderNewPrescription(app, route.patientId); break;
  }
}

window.addEventListener("hashchange", render);
updateNav();
render();
