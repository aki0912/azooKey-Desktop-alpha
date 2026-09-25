"use strict";
const $ = id => document.getElementById(id);
const node = (tag, className = "", text = "") => {
  const item = document.createElement(tag); item.className = className; item.textContent = text; return item;
};
const state = {report: null, sample: null, request: 0, abort: null};
const parts = text => Array.from(new Intl.Segmenter("ja", {granularity: "grapheme"}).segment(text), part => part.segment);
const percent = value => value === null || value === undefined ? "—" : (100 * value).toFixed(1) + "%";
const count = value => value ?? 0;

function segments(raw, labels) {
  const line = node("div", "segments"); const chars = Array.from(raw);
  for (let i = 0; i < chars.length;) {
    let end = i + 1; while (end < chars.length && labels[end] === labels[i]) end++;
    const span = node("span", "segment " + labels[i], chars.slice(i, end).join(""));
    span.title = `${labels[i]} · ${i}–${end}`; line.append(span); i = end;
  }
  return line;
}

function syncPrefix() {
  const length = parts($("raw").value).length;
  $("prefix").max = Math.max(1, length); $("prefix").value = Math.max(1, length);
  $("prefix").disabled = length === 0; updatePrefixCount();
}
function currentRaw() { return parts($("raw").value).slice(0, Number($("prefix").value)).join(""); }
function updatePrefixCount() { $("prefixCount").textContent = `${parts(currentRaw()).length} / ${parts($("raw").value).length} 文字`; }
function contextCount() { $("contextCount").textContent = $("contextAvailable").checked ? `${Array.from($("context").value).length} / 30` : "取得不可"; }
function dirty() {
  state.request++; state.abort?.abort(); $("predict").disabled = false;
  $("inferenceStatus").textContent = "未判定"; $("error").textContent = "";
  $("predictionCards").replaceChildren(node("p", "hint", "「判定する」で現在の入力を確認できます。"));
  $("scores").querySelector("tbody").replaceChildren();
  $("reference").replaceChildren();
}
function reference(raw) {
  const target = $("reference"); target.replaceChildren();
  const sample = state.sample;
  if (!sample || !sample.raw.startsWith(raw) || $("raw").value !== sample.raw ||
      sample.context_available !== $("contextAvailable").checked ||
      (sample.context_available && sample.left_context !== $("context").value)) {
    target.append(node("p", "hint", "自由入力のため、正解ラベルとの比較はありません。")); return;
  }
  target.append(node("strong", "", `正解ラベル · ${sample.id} / ${sample.split}`));
  target.append(segments(raw, sample.gold.slice(0, Array.from(raw).length)));
  target.append(node("p", "hint", "意図した表記：" + (sample.desired_display ?? "意図を固定しない例")));
}

async function predict() {
  const raw = currentRaw(); const available = $("contextAvailable").checked;
  if (!raw || Array.from(raw).length > 256 || (available && Array.from($("context").value).length > 30)) {
    $("error").textContent = "rawは1〜256文字、左文脈は30文字以内で入力してください。"; return;
  }
  state.abort?.abort(); state.abort = new AbortController(); const request = ++state.request;
  $("predict").disabled = true; $("inferenceStatus").textContent = "計算中…"; $("error").textContent = "";
  const payload = {raw, context_available: available};
  if (available) payload.left_context = $("context").value;
  try {
    const response = await fetch("/api/infer", {method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify(payload), signal: state.abort.signal});
    const result = await response.json(); if (!response.ok) throw new Error(result.error);
    if (request !== state.request) return;
    renderPrediction(raw, result); reference(raw); $("inferenceStatus").textContent = `${Array.from(raw).length}文字を判定`;
  } catch (error) {
    if (error.name !== "AbortError" && request === state.request) {
      $("error").textContent = error.message; $("inferenceStatus").textContent = "判定できませんでした";
    }
  } finally { if (request === state.request) $("predict").disabled = false; }
}

function renderPrediction(raw, result) {
  const cards = $("predictionCards"); cards.replaceChildren();
  for (const name of ["v1", "v2"]) {
    const trained = state.report.models[name]; const output = result.models[name]; const card = node("div", "model-card");
    const head = node("div", "model-head"); head.append(node("span", "model-version", name),
      node("strong", "", name === "v1" ? "rawのみ" : "raw＋確定済み左文脈"),
      node("span", "model-tag", trained.phase === "fitted" ? "未校正" : "校正済み"));
    card.append(head, segments(raw, output.labels));
    const labels = output.labels;
    card.append(node("p", "model-detail", `日本語 ${labels.filter(x => x === "JA_ROMAN").length} · 英字 ${labels.filter(x => x === "RAW").length} · 保留 ${labels.filter(x => x === "UNRESOLVED").length} 文字`));
    cards.append(card);
  }
  const body = $("scores").querySelector("tbody"); body.replaceChildren();
  Array.from(raw).forEach((char, i) => {
    const tr = node("tr"); tr.append(node("td", "", String(i)), node("td", "", char === " " ? "␠" : char));
    for (const name of ["v1", "v2"]) {
      const p = result.models[name].scores[i]; const td = node("td"); const content = node("div", "score-cell");
      const bar = node("div", "score-bar"); const fill = node("div", "score-fill"); fill.style.width = `${p * 100}%`; bar.append(fill);
      content.append(bar, node("span", "", p.toFixed(3))); td.append(content); tr.append(td);
      td.title = `${result.protections[i]} / logit ${result.models[name].logits[i].toFixed(4)}`;
    }
    body.append(tr);
  });
}

function chooseSample(id) {
  state.sample = state.report.samples.find(sample => sample.id === id) ?? null;
  if (!state.sample) return;
  const sample = state.sample; $("sample").value = id; $("raw").value = sample.raw;
  $("contextAvailable").checked = sample.context_available; $("context").value = sample.left_context ?? "";
  $("context").disabled = !sample.context_available; contextCount(); syncPrefix(); dirty(); predict();
}

function mismatches(sample, name) {
  let total = 0, wrong = 0; const chars = Array.from(sample.raw);
  sample.gold.forEach((gold, i) => {
    if (["RAW", "JA_ROMAN"].includes(gold) && /^[A-Za-z]$/.test(chars[i])) {
      total++; if (sample.predictions[name].labels[i] !== gold) wrong++;
    }
  });
  return total ? `${wrong} / ${total}文字` : "採点対象なし";
}

function renderEvaluation() {
  const split = $("partition").value; const partition = state.report.partitions[split];
  const description = {train: "学習に使ったデータです。未知の入力への性能を示しません。", dev: "Cの選択に使ったデータです。独立した最終評価ではありません。",
    calibration: "校正用に確保した原文です。件数不足のため、校正に未使用の場合があります。", test: "学習・Cの選択に使っていない原文です。件数が少なく、今回の参考診断に限られます。"}[split];
  $("partitionNote").textContent = `${partition.originals}原文 / ${partition.groups} group。${description} 増強行を除いて採点しています。`;
  $("metrics").replaceChildren();
  for (const name of ["v1", "v2"]) {
    const model = state.report.models[name]; const m = model.partitions[split]; const c = m.counts;
    const box = node("div", "metric-model"); box.append(node("h3", "", `${name} · ${model.phase === "fitted" ? "未校正モデルの参考値" : "校正済みモデル"}`));
    const grid = node("div", "metric-grid");
    for (const [label, value, denominator] of [
      ["日本語の再現率", percent(m.ja_recall), `${count(c.tp)} / ${count(c.tp) + count(c.fn)}文字`],
      ["英語区間の破壊率", percent(m.english_span_damage_rate), `${count(c.damaged_english_spans)} / ${count(c.english_spans)}区間`],
      ["保留率", percent(m.hold_rate), `${count(c.held)} / ${m.positions}文字`]]) {
      const metric = node("div"); metric.append(node("div", "metric-label", label), node("div", "metric-value", value), node("div", "metric-denom", denominator)); grid.append(metric);
    }
    box.append(grid);
    box.append(node("p", "hint", `Brier ${m.brier === null ? "—" : m.brier.toFixed(3)} · 英語破壊率の95%区間 ${m.english_damage_wilson95 ? m.english_damage_wilson95.map(percent).join("〜") : "—"}`));
    $("metrics").append(box);
  }
  const body = $("cases").querySelector("tbody"); body.replaceChildren();
  for (const sample of state.report.samples.filter(s => s.split === split)) {
    const tr = node("tr"); const raw = node("td", "case-raw"); raw.append(node("span", "case-id", sample.id), document.createTextNode(sample.raw));
    tr.append(raw, node("td", "", sample.desired_display ?? "意図を固定しない"), node("td", "mismatch", mismatches(sample, "v1")), node("td", "mismatch", mismatches(sample, "v2")));
    const td = node("td"); const inspect = node("button", "inspect", "試す"); inspect.type = "button";
    inspect.addEventListener("click", () => { chooseSample(sample.id); $("raw").scrollIntoView({behavior: "smooth", block: "center"}); });
    td.append(inspect); tr.append(td); body.append(tr);
  }
}

async function start() {
  const response = await fetch("/api/report"); if (!response.ok) throw new Error("学習レポートを読み込めませんでした。");
  state.report = await response.json(); const report = state.report;
  const blocked = Object.values(report.models).some(model => model.phase === "fitted"); const cal = report.partitions.calibration;
  const insufficient = Object.values(report.models).some(model => model.calibration.reason === "calibration partition has insufficient examples of both labels");
  $("phaseBadge").textContent = blocked ? "学習済み · 校正未完了" : "学習・校正済み · 検証用";
  $("notice").textContent = blocked
    ? `LRの学習は完了しました。${insufficient ? `校正データは日本語 ${cal.ja_positions}文字・英語 ${cal.raw_positions}文字で、各100文字以上の条件を満たしていません。` : "校正処理は完了していません。詳しい理由は学習レポートに記録しています。"}条件は緩めず、未校正の結果を表示しています。本番利用の品質は未確認です。`
    : "学習と校正は完了しています。少数の自作データによる検証結果で、本番利用の品質を保証するものではありません。";
  const stats = [["用途承認済みの原文", report.original_count, "内容確認の範囲は承認記録を参照"], ["分割後の増強データ", report.row_count, `別表記 ${report.augmentation_counts.roman_variant ?? 0} / prefix ${report.augmentation_counts.prefix ?? 0}`],
    ["比較するモデル", "v1 / v2", "同じgroup分割でLRを学習"], ["テスト用の原文", report.partitions.test.originals, "少数データの参考診断"]];
  for (const [label, value, note] of stats) { const card = node("div", "stat"); card.append(node("div", "stat-label", label), node("div", "stat-value", String(value)), node("div", "stat-note", note)); $("stats").append(card); }
  const empty = node("option", "", "自由入力"); empty.value = ""; $("sample").append(empty);
  for (const sample of report.samples) { const option = node("option", "", `${sample.id} · ${sample.split} · ${sample.raw}`); option.value = sample.id; $("sample").append(option); }
  $("scoreHint").textContent = blocked ? "0〜1の値は未校正のsigmoidスコアで、正解確率ではありません。保護・空白の位置ではこの値を判定に使いません。" : "校正済みJAスコアを表示しています。保護・空白の位置ではこの値を判定に使いません。";
  $("runInfo").textContent = `dataset ${report.dataset_sha256.slice(0, 12)} · seed ${report.seed}`;
  $("sample").addEventListener("change", () => { if ($("sample").value) chooseSample($("sample").value); else {state.sample = null; reference(currentRaw());} });
  $("raw").addEventListener("input", () => { state.sample = null; $("sample").value = ""; syncPrefix(); dirty(); reference(currentRaw()); });
  $("context").addEventListener("input", () => { contextCount(); dirty(); reference(currentRaw()); });
  $("contextAvailable").addEventListener("change", () => { $("context").disabled = !$("contextAvailable").checked; contextCount(); dirty(); reference(currentRaw()); });
  $("prefix").addEventListener("input", () => { updatePrefixCount(); dirty(); reference(currentRaw()); });
  $("prefix").addEventListener("change", predict); $("predict").addEventListener("click", predict);
  $("partition").addEventListener("change", renderEvaluation);
  renderEvaluation(); chooseSample(report.samples[0].id);
}
start().catch(error => { $("notice").textContent = error.message; $("error").textContent = error.message; });
