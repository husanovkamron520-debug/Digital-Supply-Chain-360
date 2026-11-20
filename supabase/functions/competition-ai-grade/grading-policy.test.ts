import {
  buildAiAuthorshipAssessment,
  collectSubmissionText,
  parseModelJson,
  penaltyRateForLikelihood,
  validateRubric,
} from "./grading-policy.ts";

Deno.test("rubric accepts a valid 100-point scheme", () => {
  const rubric = validateRubric({ criteria: [
    { name: "A", max_points: 60, description: "A" },
    { name: "B", max_points: 40, description: "B" },
  ] });
  if (rubric.length !== 2) throw new Error("Expected two criteria");
});

Deno.test("rubric rejects incorrect totals and duplicate names", () => {
  let badTotal = false;
  try {
    validateRubric({ criteria: [{ name: "A", max_points: 99, description: "A" }] });
  } catch { badTotal = true; }
  if (!badTotal) throw new Error("A 99-point rubric must be rejected");

  let duplicate = false;
  try {
    validateRubric({ criteria: [
      { name: "A", max_points: 50, description: "A" },
      { name: "a", max_points: 50, description: "B" },
    ] });
  } catch { duplicate = true; }
  if (!duplicate) throw new Error("Duplicate criterion names must be rejected");
});

Deno.test("model JSON parser accepts fenced JSON and rejects arrays", () => {
  const parsed = parseModelJson('```json\n{"score": 80}\n```');
  if (parsed.score !== 80) throw new Error("JSON content was not parsed");
  let rejected = false;
  try { parseModelJson("[1,2,3]"); } catch { rejected = true; }
  if (!rejected) throw new Error("Top-level arrays must be rejected");
});

Deno.test("submission text collector handles nested values", () => {
  const text = collectSubmissionText({ answer: "hello", values: [2, true] });
  if (!text.includes("answer hello") || !text.includes("2") || !text.includes("true")) {
    throw new Error("Nested submission text was not collected");
  }
});

Deno.test("authorship penalty thresholds are stable", () => {
  const expected = new Map([[49, 0], [50, 0.15], [60, 0.30], [70, 0.45], [80, 0.65], [90, 0.80]]);
  for (const [score, rate] of expected) {
    if (penaltyRateForLikelihood(score) !== rate) {
      throw new Error(`Unexpected penalty at ${score}%`);
    }
  }
});

Deno.test("AI detector never changes academic rubric score automatically", () => {
  const longText = Array.from({ length: 120 }, (_, i) => `analysis evidence calculation ${i}`).join(" ");
  const high = buildAiAuthorshipAssessment(84, longText, 88, "high");
  if (high.academic_score !== 84) throw new Error("Academic score must remain the rubric score");
  if (high.suggested_score >= high.academic_score) throw new Error("High-confidence suggestion should be calculated");
  const medium = buildAiAuthorshipAssessment(84, longText, 99, "medium");
  if (!medium.penalty_deferred || medium.suggested_score !== 84) {
    throw new Error("Medium-confidence detection must not suggest a deduction");
  }
  const short = buildAiAuthorshipAssessment(84, "Short answer", 99, "high");
  if (!short.penalty_deferred || short.suggested_score !== 84) {
    throw new Error("Short submissions must not receive a deduction suggestion");
  }
});
