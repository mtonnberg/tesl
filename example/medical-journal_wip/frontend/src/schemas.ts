/**
 * Zod schemas for MedicalJournal API types.
 *
 * These schemas mirror the Tesl type definitions in MedicalJournalModels.tesl
 * and MedicalJournalBackend.tesl.  They provide runtime validation for every
 * JSON payload exchanged with the backend.
 */

import { z } from "zod";

// ── ADT enums ───────────────────────────────────────────────────────────────

export const ProviderRole = z.enum([
  "Physician",
  "Nurse",
  "Specialist",
  "Admin",
]);
export type ProviderRole = z.infer<typeof ProviderRole>;

export const EntryType = z.enum(["Note", "Diagnosis", "LabResult", "Procedure"]);
export type EntryType = z.infer<typeof EntryType>;

export const Severity = z.enum(["Routine", "Urgent", "Critical"]);
export type Severity = z.infer<typeof Severity>;

export const PrescriptionStatus = z.enum(["Active", "Completed", "Cancelled"]);
export type PrescriptionStatus = z.infer<typeof PrescriptionStatus>;

export const PatientStatus = z.enum([
  "ActivePatient",
  "Discharged",
  "Transferred",
]);
export type PatientStatus = z.infer<typeof PatientStatus>;

// ── Entity schemas (API responses) ──────────────────────────────────────────

export const Provider = z.object({
  id: z.string(),
  email: z.string(),
  passwordHash: z.string(),
  displayName: z.string(),
  role: ProviderRole,
  department: z.string(),
  createdAt: z.number(),
});
export type Provider = z.infer<typeof Provider>;

export const Patient = z.object({
  id: z.string(),
  medicalRecordNumber: z.string(),
  firstName: z.string(),
  lastName: z.string(),
  dateOfBirth: z.string(),
  bloodType: z.string(),
  allergies: z.string(),
  status: PatientStatus,
  primaryProviderId: z.string(),
  createdAt: z.number(),
  updatedAt: z.number(),
});
export type Patient = z.infer<typeof Patient>;

export const JournalEntry = z.object({
  id: z.string(),
  patientId: z.string(),
  entryType: EntryType,
  title: z.string(),
  content: z.string(),
  severity: Severity,
  authorId: z.string(),
  createdAt: z.number(),
});
export type JournalEntry = z.infer<typeof JournalEntry>;

export const Prescription = z.object({
  id: z.string(),
  patientId: z.string(),
  journalEntryId: z.string(),
  medication: z.string(),
  dosage: z.string(),
  frequency: z.string(),
  durationDays: z.number().int(),
  status: PrescriptionStatus,
  prescribedBy: z.string(),
  createdAt: z.number(),
});
export type Prescription = z.infer<typeof Prescription>;

export const DomainEvent = z.object({
  id: z.string(),
  aggregateType: z.string(),
  aggregateId: z.string(),
  eventType: z.string(),
  summary: z.string(),
  actorId: z.string(),
  createdAt: z.number(),
});
export type DomainEvent = z.infer<typeof DomainEvent>;

// ── Request schemas ─────────────────────────────────────────────────────────

export const LoginRequest = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});
export type LoginRequest = z.infer<typeof LoginRequest>;

export const LoginResponse = z.object({
  providerId: z.string(),
  displayName: z.string(),
  role: ProviderRole,
  token: z.string(),
});
export type LoginResponse = z.infer<typeof LoginResponse>;

export const NewPatientRequest = z.object({
  firstName: z.string().min(1),
  lastName: z.string().min(1),
  dateOfBirth: z.string(),
  bloodType: z.string(),
  allergies: z.string(),
});
export type NewPatientRequest = z.infer<typeof NewPatientRequest>;

export const NewJournalEntryRequest = z.object({
  entryType: EntryType,
  title: z.string().min(1),
  content: z.string().min(1),
  severity: Severity,
});
export type NewJournalEntryRequest = z.infer<typeof NewJournalEntryRequest>;

export const NewPrescriptionRequest = z.object({
  medication: z.string().min(1),
  dosage: z.string().min(1),
  frequency: z.string().min(1),
  durationDays: z.number().int().positive(),
});
export type NewPrescriptionRequest = z.infer<typeof NewPrescriptionRequest>;

export const UpdatePatientStatusRequest = z.object({
  status: PatientStatus,
});
export type UpdatePatientStatusRequest = z.infer<
  typeof UpdatePatientStatusRequest
>;
