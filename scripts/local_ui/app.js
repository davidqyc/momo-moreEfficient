"use strict";

const sessionSecret = window.location.hash.slice(1);
const HEARTBEAT_MS = 15000;
const batchInput = document.querySelector("#batch-input");
const connectButton = document.querySelector("#connect-button");
const previewButton = document.querySelector("#preview-button");
const quitButton = document.querySelector("#quit-button");
const createButton = document.querySelector("#create-button");
const updateButton = document.querySelector("#update-button");
const connectionState = document.querySelector("#connection-state");
const notice = document.querySelector("#notice");
const previewPanel = document.querySelector("#preview-panel");
const resultPanel = document.querySelector("#result-panel");
const resultSummary = document.querySelector("#result-summary");
const counts = document.querySelector("#counts");
const rows = document.querySelector("#rows");

let connected = false;
let previewNonce = "";
let latestCounts = {create: 0, update: 0, matching: 0, blocked: 0};

function setConnected(value) {
  connected = value;
  connectionState.textContent = value ? "已连接 · 仅本进程" : "未连接";
  connectionState.classList.toggle("connected", value);
  previewButton.disabled = !value;
}

async function api(path, payload) {
  const response = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Momo-Session": sessionSecret,
    },
    body: JSON.stringify(payload),
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(body.error || "本地请求失败。");
  }
  return body;
}

function setBusy(button, busy) {
  button.disabled = busy;
  button.setAttribute("aria-busy", busy ? "true" : "false");
}

function showNotice(message, error = false) {
  notice.textContent = message;
  notice.classList.toggle("error", error);
}

function invalidatePreview() {
  previewNonce = "";
  createButton.disabled = true;
  updateButton.disabled = true;
  if (!previewPanel.classList.contains("hidden")) {
    showNotice("输入已改变，请重新预览。", false);
  }
}

function countChip(label, value) {
  const chip = document.createElement("span");
  chip.className = "count";
  chip.textContent = `${label} ${value}`;
  return chip;
}

function interpretation(text) {
  const node = document.createElement("p");
  node.className = "interpretation";
  node.textContent = text;
  return node;
}

function renderRow(item) {
  const row = document.createElement("article");
  row.className = "row";
  const head = document.createElement("div");
  head.className = "row-head";
  const word = document.createElement("h3");
  word.className = "word";
  word.textContent = item.spelling;
  const badge = document.createElement("span");
  badge.className = `badge ${item.state}`;
  badge.textContent = item.state;
  head.append(word, badge);
  row.append(head);

  if (item.state === "UPDATE") {
    const comparison = document.createElement("div");
    comparison.className = "comparison";
    for (const [label, value] of [["CURRENT", item.current], ["PROPOSED", item.proposed]]) {
      const column = document.createElement("div");
      const title = document.createElement("h4");
      title.textContent = label;
      column.append(title, interpretation(value));
      comparison.append(column);
    }
    row.append(comparison);
  } else {
    row.append(interpretation(item.proposed));
  }
  return row;
}

function render(data) {
  previewNonce = data.preview_nonce;
  latestCounts = data.counts;
  counts.replaceChildren(
    countChip("新建", data.counts.create),
    countChip("更新", data.counts.update),
    countChip("已一致", data.counts.matching),
    countChip("阻断", data.counts.blocked),
  );
  rows.replaceChildren(...data.items.map(renderRow));
  createButton.textContent = `执行新建（${data.counts.create}）`;
  updateButton.textContent = `执行更新（${data.counts.update}）`;
  createButton.disabled = !data.actions.create;
  updateButton.disabled = !data.actions.update;
  previewPanel.classList.remove("hidden");
  if (data.summary) {
    resultSummary.textContent = `新建 ${data.summary.created} / 更新 ${data.summary.updated} / 已一致 ${data.summary.matching} / 失败 ${data.summary.failed}`;
    resultPanel.classList.remove("hidden");
  }
}

connectButton.addEventListener("click", async () => {
  setConnected(false);
  invalidatePreview();
  setBusy(connectButton, true);
  showNotice("请在系统弹窗中输入主账号 Token；答案会隐藏显示。", false);
  try {
    await api("/api/connect", {});
    setConnected(true);
    showNotice("主账号已连接。Token 未进入网页，也不会保存。", false);
  } catch (error) {
    setConnected(false);
    showNotice(error.message, true);
  } finally {
    connectButton.disabled = false;
  }
});

previewButton.addEventListener("click", async () => {
  if (!connected) return;
  setBusy(previewButton, true);
  showNotice("正在只读预览；不会发送 POST。", false);
  try {
    const data = await api("/api/preview", {document: batchInput.value});
    render(data);
    showNotice("预览完成。请逐项检查后再执行对应操作组。", false);
  } catch (error) {
    invalidatePreview();
    showNotice(error.message, true);
  } finally {
    previewButton.disabled = false;
  }
});

async function execute(path, button) {
  if (!previewNonce) return;
  setBusy(button, true);
  showNotice("正在重新预检并核对计划；只有完全一致才会写入。", false);
  try {
    const data = await api(path, {
      document: batchInput.value,
      preview_nonce: previewNonce,
    });
    render(data);
    if (data.result && data.result.stopped) {
      previewNonce = "";
      showNotice(data.result.message, true);
    } else {
      showNotice("执行完成，写后回读验证通过。", false);
    }
  } catch (error) {
    invalidatePreview();
    showNotice(error.message, true);
  } finally {
    if (path.endsWith("create")) {
      createButton.disabled = true;
    } else {
      updateButton.disabled = true;
    }
  }
}

createButton.addEventListener("click", () => execute("/api/execute-create", createButton));
updateButton.addEventListener("click", () => execute("/api/execute-update", updateButton));
batchInput.addEventListener("input", invalidatePreview);

async function heartbeat() {
  // A hidden/abandoned tab must not keep a main-account Token alive forever.
  // Returning to the visible tab performs an immediate status recovery below.
  if (document.visibilityState !== "visible") {
    return;
  }
  try {
    const state = await api("/api/heartbeat", {});
    setConnected(Boolean(state.connected));
    if (!state.connected) {
      invalidatePreview();
    }
  } catch (_error) {
    setConnected(false);
    invalidatePreview();
  }
}

heartbeat();
window.setInterval(heartbeat, HEARTBEAT_MS);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    heartbeat();
  }
});

quitButton.addEventListener("click", async () => {
  try {
    await api("/api/quit", {});
    document.body.replaceChildren(document.createTextNode("本地服务已退出，可以关闭此页面。"));
  } catch (error) {
    showNotice(error.message, true);
  }
});
