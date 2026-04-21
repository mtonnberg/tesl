/**
 * Typed API client for MedicalJournal Tesl backend.
 *
 * Every response is validated at runtime through Zod schemas that mirror the
 * Tesl type definitions.  The client handles cookie-based auth automatically
 * after a successful login.
 */

import { z } from "zod";
import {
  LoginRequest,
  LoginResponse,
  NewPatientRequest,
  Patient,
  JournalEntry,
  NewJournalEntryRequest,
  Prescription,
  NewPrescriptionRequest,
  UpdatePatientStatusRequest,
  DomainEvent,
} from "./schemas.js";

// ── Error types ─────────────────────────────────────────────────────────────

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: unknown,
  ) {
    super(`API error ${status}`);
    this.name = "ApiError";
  }
}

export class ValidationError extends Error {
  constructor(
    public readonly issues: z.ZodIssue[],
    public readonly rawBody: unknown,
  ) {
    super(`Response validation failed: ${issues.map((i) => i.message).join(", ")}`);
    this.name = "ValidationError";
  }
}

// ── Client ──────────────────────────────────────────────────────────────────

export interface ClientOptions {
  baseUrl: string;
  /** Override fetch (useful for testing / SSR) */
  fetch?: typeof globalThis.fetch;
}

export function createClient(options: ClientOptions) {
  const { baseUrl } = options;
  const fetchFn = options.fetch ?? globalThis.fetch.bind(globalThis);
  let authCookie: string | undefined;

  async function request<T>(
    method: string,
    path: string,
    schema: z.ZodType<T>,
    body?: unknown,
  ): Promise<T> {
    const headers: Record<string, string> = {};
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    if (authCookie) {
      headers["Cookie"] = authCookie;
    }

    const res = await fetchFn(`${baseUrl}${path}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });

    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new ApiError(res.status, text);
    }

    const json: unknown = await res.json();
    const parsed = schema.safeParse(json);
    if (!parsed.success) {
      throw new ValidationError(parsed.error.issues, json);
    }
    return parsed.data;
  }

  async function requestList<T>(
    method: string,
    path: string,
    itemSchema: z.ZodType<T>,
  ): Promise<T[]> {
    return request(method, path, z.array(itemSchema));
  }

  return {
    // ── Auth ──────────────────────────────────────────────────────────────

    async login(req: LoginRequest): Promise<LoginResponse> {
      const data = await request("POST", "/auth/login", LoginResponse, req);
      // Store the token as a cookie for subsequent requests
      authCookie = `mj_provider_id=${data.token}`;
      return data;
    },

    logout() {
      authCookie = undefined;
    },

    // ── Patients ──────────────────────────────────────────────────────────

    async createPatient(req: NewPatientRequest): Promise<Patient> {
      return request("POST", "/patients", Patient, req);
    },

    async listPatients(): Promise<Patient[]> {
      return requestList("GET", "/patients", Patient);
    },

    async getPatient(patientId: string): Promise<Patient> {
      return request("GET", `/patients/${patientId}`, Patient);
    },

    async updatePatientStatus(
      patientId: string,
      req: UpdatePatientStatusRequest,
    ): Promise<Patient> {
      return request("PUT", `/patients/${patientId}/status`, Patient, req);
    },

    // ── Journal entries ──────────────────────────────────────────────────

    async addJournalEntry(
      patientId: string,
      req: NewJournalEntryRequest,
    ): Promise<JournalEntry> {
      return request(
        "POST",
        `/patients/${patientId}/entries`,
        JournalEntry,
        req,
      );
    },

    async listJournalEntries(patientId: string): Promise<JournalEntry[]> {
      return requestList("GET", `/patients/${patientId}/entries`, JournalEntry);
    },

    // ── Prescriptions ────────────────────────────────────────────────────

    async addPrescription(
      patientId: string,
      req: NewPrescriptionRequest,
    ): Promise<Prescription> {
      return request(
        "POST",
        `/patients/${patientId}/prescriptions`,
        Prescription,
        req,
      );
    },

    async listPrescriptions(patientId: string): Promise<Prescription[]> {
      return requestList(
        "GET",
        `/patients/${patientId}/prescriptions`,
        Prescription,
      );
    },

    // ── Timeline (CQRS read model) ──────────────────────────────────────

    async getTimeline(patientId: string): Promise<DomainEvent[]> {
      return requestList(
        "GET",
        `/patients/${patientId}/timeline`,
        DomainEvent,
      );
    },
  };
}

export type MedicalJournalClient = ReturnType<typeof createClient>;
