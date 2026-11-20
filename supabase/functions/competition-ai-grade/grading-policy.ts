export type Criterion = { name: string; max_points: number; description: string };
export type GradeCriterion = {
  name: string;
  max_points: number;
  awarded_points: number;
  evidence: string;
  feedback: string;
};

export function validateRubric(value: unknown): Criterion[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Rubric must be an object containing criteria.");
  }
  const raw = (value as Record<string, unknown>).criteria;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 10) {
    throw new Error("Rubric must contain 1–10 criteria.");
  }
  const criteria = raw.map((item): Criterion => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("Invalid rubric criterion.");
    }
    const x = item as Record<string, unknown>;
    if (typeof x.name !== "string" || !x.name.trim() ||
        typeof x.description !== "string" ||
        typeof x.max_points !== "number" || !Number.isFinite(x.max_points) ||
        x.max_points < 0 || x.max_points > 100) {
      throw new Error("Invalid rubric criterion fields.");
    }
    return { name: x.name.trim(), description: x.description, max_points: x.max_points };
  });
  const total = criteria.reduce((sum, x) => sum + x.max_points, 0);
  if (Math.abs(total - 100) > 0.001) {
    throw new Error("Rubric weights must total exactly 100.");
  }
  if (new Set(criteria.map((x) => x.name.toLocaleLowerCase())).size !== criteria.length) {
    throw new Error("Rubric criterion names must be unique.");
  }
  return criteria;
}

export function parseModelJson(text: string): Record<string, unknown> {
  const cleaned = text.trim()
    .replace(/^\x60{3}(?:json)?\s*/i, "")
    .replace(/\s*\x60{3}$/i, "");
  const parsed = JSON.parse(cleaned);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("AI returned a non-object result.");
  }
  return parsed as Record<string, unknown>;
}

export function collectSubmissionText(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return value.map(collectSubmissionText).join(" ");
  if (value && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .map(([key, item]) => key + " " + collectSubmissionText(item))
      .join(" ");
  }
  return "";
}

export function penaltyRateForLikelihood(likelihood: number): number {
  if (likelihood >= 90) return 0.80;
  if (likelihood >= 80) return 0.65;
  if (likelihood >= 70) return 0.45;
  if (likelihood >= 60) return 0.30;
  if (likelihood >= 50) return 0.15;
  return 0;
}

/**
 * Authorship is a weak signal, never proof. The rubric score is preserved.
 * A deduction is only a teacher-facing suggestion when the text is substantial
 * and Gemini reports high confidence. The suggestion is never auto-applied.
 */
export function buildAiAuthorshipAssessment(
  baseScore: number,
  submissionText: string,
  likelihoodInput: unknown,
  confidenceInput: unknown,
) {
  const wordCount = (submissionText.match(/[\p{L}\p{N}]+/gu) ?? []).length;
  const rawLikelihood = Number(likelihoodInput);
  const likelihood = Number.isFinite(rawLikelihood)
    ? Math.max(0, Math.min(100, Math.round(rawLikelihood)))
    : 0;
  const confidenceValue = String(confidenceInput ?? "low").toLowerCase();
  const confidence = ["low", "medium", "high"].includes(confidenceValue)
    ? confidenceValue
    : "low";
  const deferred = wordCount < 100 || submissionText.trim().length < 600 || confidence !== "high";
  const rate = deferred ? 0 : penaltyRateForLikelihood(likelihood);
  const percent = Math.round(rate * 100);
  return {
    ai_likelihood: likelihood,
    ai_confidence: confidence,
    ai_word_count: wordCount,
    penalty_percent: percent,
    penalty_rate: rate,
    penalty_deferred: deferred,
    academic_score: Math.round(baseScore * 100) / 100,
    suggested_score: Math.round(baseScore * (1 - rate) * 100) / 100,
  };
}
