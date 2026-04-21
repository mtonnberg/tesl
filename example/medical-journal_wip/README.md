# Medical Journal — CQRS Example

A medical record system built with Tesl demonstrating **event-sourced CQRS**,
**proof-gated database access**, **capability-based security**, and a
**Zod-typed TypeScript frontend**.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  MedicalJournalModels.tesl                                  │
│  Entities · ADTs · Records · Codecs                         │
├─────────────────────────────────────────────────────────────┤
│  MedicalJournalAuth.tesl                                    │
│  Cookie auth · Authenticated · IsPhysician                  │
├─────────────────────────────────────────────────────────────┤
│  MedicalJournalValidation.tesl                              │
│  10 GDP proof facts + check functions                       │
├─────────────────────────────────────────────────────────────┤
│  MedicalJournalDB.tesl                                      │
│  Proof-gated DB functions — no raw SQL without proofs       │
├─────────────────────────────────────────────────────────────┤
│  MedicalJournalBackend.tesl                                 │
│  Thin handlers · API · Server · 27 api-tests · 4 load-tests│
├─────────────────────────────────────────────────────────────┤
│  frontend/                                                  │
│  Vanilla TypeScript SPA · Zod validation · esbuild          │
└─────────────────────────────────────────────────────────────┘
```

### Layered Proof Architecture

Handlers never touch the database directly.  Instead they:
1. **Validate inputs** via `check` functions → GDP proofs
2. **Call DB functions** that demand those proofs in their signatures

If a handler omits a validation step, the code **fails to compile**.

```
Request → Handler → checkValidPatientName → dbInsertPatient
                    checkPatientIsActive       ↑ requires proofs
                    checkIsPhysician           ↑ in signature
```

### GDP Proofs

| Proof | Meaning | Enforced by |
|---|---|---|
| `Authenticated session` | Valid provider cookie | `cookieAuth` |
| `IsPhysician providerId` | Role is Physician or Specialist | `checkIsPhysician` |
| `ValidPatientName name` | Non-empty, ≤200 chars | `checkValidPatientName` |
| `ValidDateOfBirth dob` | Non-empty | `checkValidDateOfBirth` |
| `PatientExists patientId` | Patient found in DB | `checkPatientExists` |
| `PatientIsActive patientId` | Status is ActivePatient | `checkPatientIsActive` |
| `ValidJournalTitle title` | Non-empty, ≤500 chars | `checkValidJournalTitle` |
| `ValidJournalContent content` | Non-empty, ≤50k chars | `checkValidJournalContent` |
| `ValidMedication medication` | Non-empty, ≤300 chars | `checkValidMedication` |
| `ValidDosage dosage` | Non-empty | `checkValidDosage` |
| `ValidFrequency frequency` | Non-empty | `checkValidFrequency` |
| `ValidDuration durationDays` | 1–365 days | `checkValidDuration` |

### Example: Prescription requires triple proof chain

```tesl
handler addPrescription(session ::: Authenticated, patientId, req) =
  let physicianId = checkIsPhysician session.providerId session.role   # proof 1
  let activePatient = checkPatientIsActive patientId                   # proof 2
  let medication = checkValidMedication req.medication                 # proof 3a
  let dosage = checkValidDosage req.dosage                             # proof 3b
  let frequency = checkValidFrequency req.frequency                    # proof 3c
  let duration = checkValidDuration req.durationDays                   # proof 3d
  ...
  dbInsertPrescription rxId activePatient entryId medication dosage frequency duration physicianId
  #                         ↑ PatientIsActive   ↑ ValidMedication etc.        ↑ IsPhysician
```

Remove any `check` call → **compile error** at the `dbInsertPrescription` call site.

## API Endpoints

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| POST | `/auth/login` | — | `LoginRequest` | `LoginResponse` |
| POST | `/patients` | cookie | `NewPatientRequest` | `Patient` |
| GET | `/patients` | cookie | — | `Patient[]` |
| GET | `/patients/:id` | cookie | — | `Patient` |
| PUT | `/patients/:id/status` | cookie | `UpdatePatientStatusRequest` | `Patient` |
| POST | `/patients/:id/entries` | cookie | `NewJournalEntryRequest` | `JournalEntry` |
| GET | `/patients/:id/entries` | cookie | — | `JournalEntry[]` |
| POST | `/patients/:id/prescriptions` | cookie | `NewPrescriptionRequest` | `Prescription` |
| GET | `/patients/:id/prescriptions` | cookie | — | `Prescription[]` |
| GET | `/patients/:id/timeline` | cookie | — | `DomainEvent[]` |

## Tests

### Functional tests (27 api-tests)

**Auth:** Unauthenticated rejection, login success, unknown email failure

**Patient CRUD:** Create, list, get, get-404, status update

**Journal entries:** Create + event recording, list, nonexistent patient

**Prescriptions:** Physician creates, nurse rejected, list

**CQRS flow:** Create patient → add entry → prescribe → verify timeline

**Validation proofs (11 tests):**
- Empty first name → 400
- Empty last name → 400
- Empty date of birth → 400
- Journal entry on discharged patient → 422
- Prescription on transferred patient → 422
- Empty medication → 400
- Empty dosage → 400
- Zero duration → 400
- Duration > 365 days → 400
- Empty journal title → 400
- Empty journal content → 400

### Load tests (4)

- `GET /patients` — list throughput
- `GET /patients/:id` — single lookup latency
- `GET /patients/:id/timeline` — event store query
- `POST /auth/login` — authentication throughput

## Frontend

The `frontend/` directory contains a vanilla TypeScript SPA bundled with
esbuild.  It uses the same Zod schemas as the API client library.

```bash
cd frontend && npm install && npm run build
```

The Tesl backend serves both the API and the built SPA on the same port
(SPA fallback for client-side routing).

### Pages

- **Login** — provider authentication
- **Patient list** — table with MRN, name, DOB, blood type, status
- **Patient detail** — tabbed view: journal entries, prescriptions, timeline
- **New patient form** — validated via `ValidPatientName` + `ValidDateOfBirth`
- **New journal entry** — validated via `ValidJournalTitle` + `ValidJournalContent` + `PatientIsActive`
- **New prescription** — triple proof: `IsPhysician` + `PatientIsActive` + field validations

Each page shows a blue banner explaining which GDP proofs protect that
operation — making the proof architecture visible to the user.

## Running

```bash
# Full stack (PostgreSQL + backend + frontend)
bash example/medical-journal/run.sh

# Or manually:
cd frontend && npm run build           # build SPA → dist/
tesl run MedicalJournalBackend.tesl    # API + static on :8080

# Check / lint / format
tesl --check MedicalJournalBackend.tesl
tesl --lint MedicalJournalBackend.tesl
tesl --fmt-check MedicalJournalBackend.tesl
```
