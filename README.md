# KITAB-Bench Submission — Sharon (Ninth Planet)

**Entry name:** Sharon (Ninth Planet)
**Entry type:** Production OCR system (comparable to the AzureOCR / Surya system rows, not a base-model row)
**Evaluated:** 2026-08-01, full official OCR track (all 13 datasets, 3,760 samples, split `train`)
**Scoring:** unmodified `ocr-eval/metrics.py` from `mbzuai-oryx/KITAB-Bench` (corpus-level CER/WER via torchmetrics, sacrebleu chrF, unweighted macro average across the 13 datasets)
**Contact:** Ninth Planet Publishing (House Alkokab Altasii) · support@9-pp.com · https://sharon.9-pp.com

## Headline results (recommended row: `sharonclean`)

| Variant | chrF ↑ | CER ↓ | WER ↓ |
|---|---|---|---|
| **sharonclean** (uncertainty markers stripped) | **84.14** | 0.371 | 0.545 |
| sharon (raw system output) | 83.99 | 0.376 | 0.550 |

For reference, the highest published leaderboard rows at evaluation time: AIN-7B chrF 78.33 / CER 0.20 / WER 0.28; Gemini-2.0-Flash chrF 77.95 / CER 0.13 / WER 0.32.

## Per-dataset results (sharonclean)

| Dataset | CER | WER | chrF |
|---|---|---|---|
| patsocr | 0.00 | 0.01 | 99.16 |
| arabicocr | 0.01 | 0.05 | 97.39 |
| isippt | 0.03 | 0.12 | 94.62 |
| synthesizear | 0.03 | 0.09 | 95.30 |
| historicalbooks | 0.04 | 0.16 | 89.46 |
| hindawi | 0.04 | 0.08 | 94.77 |
| onlinekhatt | 0.06 | 0.25 | 87.29 |
| adab | 0.07 | 0.31 | 83.23 |
| khatt | 0.09 | 0.36 | 81.48 |
| historyar | 0.14 | 0.40 | 74.70 |
| evarest | 0.15 | 0.28 | 89.52 |
| muharaf | 0.23 | 0.58 | 57.86 |
| khattparagraph | 3.93 | 4.39 | 49.05 |

## System description

Sharon is a commercial Arabic-first reading app (iOS). The submitted system is its
production cloud-OCR pipeline, evaluated exactly as it ships to users:

1. **On-device draft:** Apple Vision (`VNRecognizeTextRequest`, accurate, `ar-SA`)
   produces an untrusted reference draft per image (3,759/3,760 images; the draft is
   injected into the prompt as explicitly untrusted data, JSON-encoded, capped at
   12,000 chars).
2. **Fast tier:** `gemini-2.5-flash` with Sharon's production system prompt — verbatim
   transcription contract: copy printed diacritics only, RTL reading order, two-column
   handling, structure preservation (blank-line paragraphs, `## ` headings, poetry with
   hemistich separation), no correction/translation/hallucination, uncertain words
   wrapped in `⟦ ⟧`. Deterministic decoding: temperature 0, topP 1, topK 1,
   maxOutputTokens 32768.
3. **Escalation:** provider failures (non-STOP finish or empty output) escalate to
   `gemini-2.5-pro` under the same contract — identical to production behavior.

`sharonclean` strips the system's presentation markup (`⟦ ⟧` uncertainty markers and
`## ` heading prefixes) before scoring; the app renders these as UI affordances, not
text. Raw-output scores are reported alongside for transparency.

## Methodological notes & limitations

- **Prompt difference:** published VLM rows use the repository's generic prompt
  ("Extract the text in the image..."). This entry is a *system* row: the production
  prompt contract is part of the system under test, as with other system entries.
  We are happy to re-run under maintainer-specified conditions.
- **khattparagraph:** the system transcribes the full visible page; this dataset's
  ground truth covers a subset of the visible text, which inflates corpus-level CER
  (3.93) for a full-page transcriber. 21/3,760 samples produced no output after
  escalation and are scored as total failures.
- **Model dependency:** backbone model versions as served by Google on 2026-08-01
  (`gemini-2.5-flash` / `gemini-2.5-pro`).
- Total evaluation cost: ≈ $7.77 (3,789 API calls including escalations).

## Package contents

- `predictions/` — per-dataset prediction files in the repository's `results/` format
  (`{idx, gt, pred}` per sample), both variants (26 files).
- `metrics/sharon_metrics.json`, `metrics/sharonclean_metrics.json` — verbatim output
  of the repository's `metrics.py`.
- `metrics/full_run_summary.json` — run statistics (call counts, failures, spend).

## Reproduction

1. Clone `mbzuai-oryx/KITAB-Bench`; download the 13 `ahmedheakl/arocrbench_*` datasets.
2. Generate Apple Vision drafts per image (macOS, `VNRecognizeTextRequest`, accurate,
   `ar-SA`).
3. Run the pipeline above per image (system prompt available to maintainers on
   request), writing one prediction per sample.
4. Copy predictions into `ocr-eval/results/` and run
   `python metrics.py --model_name sharonclean`.
