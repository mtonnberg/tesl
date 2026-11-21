"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { renderFlow, renderFlowReview } = require("./migration-flow");

test("welcome is start-first, short, and has one primary action with optional background", () => {
  const html = renderFlow({ nonce: "abc", stage: "welcome" });
  assert.ok(html.includes("Migrate database/queues"));
  assert.ok(html.includes("Ready to start"));
  assert.ok(html.includes('data-action="start"'));
  assert.ok(!html.includes("MIG024"));
  assert.ok(!html.includes("Same"));
  assert.equal((html.match(/class="primary"/g) || []).length, 1);
  assert.ok(html.includes("About this step"));
  assert.ok(!html.includes("Why start first?"));
});

test("prepared and ready pages distinguish source checks, tests, and database execution", () => {
  const flow = { nonce: "abc", stage: "edit", revision: 14, projectRoot: "/project", schemaFiles: ["/project/schema/todo/v-current.tesl"] };
  const edit = renderFlow(flow);
  assert.ok(edit.includes("draft V14 prepared"));
  assert.ok(edit.includes("Review my changes"));
  assert.ok(edit.includes("source files, not deployed data"));
  const ready = renderFlow({ ...flow, stage: "ready" });
  assert.ok(ready.includes("source checks passed"));
  assert.ok(ready.includes("Tests have not run yet"));
  assert.ok(ready.includes('data-action="back"'));
  assert.ok(ready.includes('data-action="cancel"'));
  assert.ok(ready.includes('data-action="tests"'));
  assert.ok(ready.includes('data-action="finish"'));
  assert.ok(ready.includes("Finish keeps your migration files"));
});

test("review is concise while preserving complete option requirements in details", () => {
  const flow = { nonce: "abc", revision: 14 };
  const item = { decisionId: "entity:Todo", title: "Choose", summary: "Choose intent", options: [{ id: "migrate-validators", title: "Compiler label", when: "Use existing validators. Historical fallback policy must be supplied.", example: "Migrate convert <unsafe>" }] };
  const html = renderFlowReview(flow, { previewId: "p", compilable: false, files: [] }, [item], 0, { canChoose: true });
  assert.equal(flow.stage, "review");
  assert.ok(html.includes("Use my updated validation rules"));
  assert.ok(html.includes("Historical fallback policy must be supplied"));
  assert.ok(!html.includes("<unsafe>"));
  assert.ok(html.includes('id="generate-plan" disabled'));
  assert.equal((html.match(/class="primary"/g) || []).length, 1);
  renderFlowReview(flow, { compilable: true, files: [] }, [], 0, { busy: true });
  assert.equal(flow.stage, "review", "an in-flight source update is not completed");
  renderFlowReview(flow, { compilable: true, files: [] }, [], 0, {});
  assert.equal(flow.stage, "ready");
});

test("source readiness requires reviewed cleanup and exposes one explicit source action", () => {
  const flow = { nonce: "abc", revision: 14 };
  const preview = { operation: "refresh", compilable: true, files: [], cleanup: [{ version: 14, present: false }] };
  const required = renderFlowReview(flow, preview, [], 0, {});
  assert.equal(flow.stage, "cleanup-needed");
  assert.ok(required.includes('data-action="cleanup"'));
  assert.ok(!required.includes('data-action="tests"'));
  assert.equal((required.match(/class="primary"/g) || []).length, 1);
  const proposal = renderFlowReview(flow, { ...preview, operation: "contract", contractVersion: 14, files: [{ path: "/project/migrations/notes/v14-contract.tesl", creates: true }] }, [], 0, { canApply: true });
  assert.equal(flow.stage, "cleanup");
  assert.ok(proposal.includes("Cleanup for V14"));
  assert.ok(proposal.includes("Add reviewed cleanup source"));
  assert.equal((proposal.match(/class="primary"/g) || []).length, 1);
  renderFlowReview(flow, { ...preview, cleanup: [{ version: 14, present: true }] }, [], 0, {});
  assert.equal(flow.stage, "ready");
});
