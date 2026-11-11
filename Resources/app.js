(function () {
  "use strict";

  const fmt = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 });
  const integerFormatter = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 });
  const byId = (id) => document.getElementById(id);
  let noticeTimer = null;
  let usageAlertThresholdPercent = 20;
  let deepSeekBalanceAlertThreshold = 10;
  let deepSeekBalanceAlertCurrency = "CNY";
  let latestSnapshot = null;

  function native(action, extra = {}) {
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaaaa;
    if (bridge) bridge.postMessage(Object.assign({ action }, extra));
  }

  function value(object, key, fallback) {
    return object && object[key] !== undefined && object[key] !== null ? object[key] : fallback;
  }

  function tokenNumber(input) {
    const number = Number(input);
    return Number.isFinite(number) ? fmt.format(number) : "—";
  }

  function amount(input, currency) {
    const formatted = exactDecimal(input);
    if (formatted === null) return "—";
    if (currency === "CNY") return "¥" + formatted;
    if (currency === "USD") return "$" + formatted;
    return formatted + " " + currency;
  }

  function exactDecimal(input) {
    const normalized = normalizeDecimal(input);
    if (normalized === null) return null;
    const match = normalized.match(/^(-?)(\d+)(?:\.(\d+))?$/);
    if (!match) return null;
    const negative = match[1] === "-";
    const whole = match[2].replace(/^0+(?=\d)/, "");
    let fraction = match[3] || "";
    while (fraction.length > 2 && fraction.endsWith("0")) fraction = fraction.slice(0, -1);
    if (fraction.length < 2) fraction = fraction.padEnd(2, "0");
    return (negative ? "-" : "") + integerFormatter.format(BigInt(whole)) + "." + fraction;
  }

  function normalizeDecimal(input) {
    const match = String(input).trim().match(/^(-?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/);
    if (!match) return null;
    const sign = match[1];
    const whole = match[2];
    const fraction = match[3] || "";
    const exponent = Number(match[4] || "0");
    if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 1000) return null;
    const digits = whole + fraction;
    const point = whole.length + exponent;
    if (point <= 0) return sign + "0." + "0".repeat(-point) + digits;
    if (point >= digits.length) return sign + digits + "0".repeat(point - digits.length);
    return sign + digits.slice(0, point) + "." + digits.slice(point);
  }

  function addDecimalStrings(values) {
    const matches = values.map((value) => {
      const normalized = normalizeDecimal(value);
      return normalized === null ? null : normalized.match(/^(-?)(\d+)(?:\.(\d+))?$/);
    });
    if (matches.some((match) => !match)) return null;
    const scale = Math.max(0, ...matches.map((match) => (match[3] || "").length));
    const factor = 10n ** BigInt(scale);
    let total = 0n;
    for (const match of matches) {
      const fraction = (match[3] || "").padEnd(scale, "0");
      const magnitude = BigInt(match[2]) * factor + BigInt(fraction || "0");
      total += match[1] === "-" ? -magnitude : magnitude;
    }
    const negative = total < 0n;
    const magnitude = negative ? -total : total;
    const whole = magnitude / factor;
    const fractionValue = String(magnitude % factor).padStart(scale, "0");
    const raw = (negative ? "-" : "") + String(whole) + (scale ? "." + fractionValue : "");
    return exactDecimal(raw);
  }

  function groupedAmounts(items) {
    if (!Array.isArray(items) || !items.length) return null;
    const amounts = new Map();
    for (const item of items) {
      const currency = item && item.currency;
      const value = item && item.amount;
      if ((currency === "CNY" || currency === "USD") && exactDecimal(value) !== null) {
        if (!amounts.has(currency)) amounts.set(currency, []);
        amounts.get(currency).push(String(value));
      }
    }
    if (!amounts.size) return null;
    return Array.from(amounts.entries())
      .map(([currency, values]) => amount(addDecimalStrings(values), currency))
      .join("  ·  ");
  }

  function deepSeekBalanceIsAtOrBelowAlert(deepseek) {
    const balances = deepseek && Array.isArray(deepseek.balances) ? deepseek.balances : [];
    const selected = balances.find((item) => item && item.currency === deepSeekBalanceAlertCurrency);
    if (!selected || selected.amount === undefined || selected.amount === null) return false;
    const amount = Number(selected.amount);
    return Number.isFinite(amount) && amount <= deepSeekBalanceAlertThreshold;
  }

  function resetText(resetAt) {
    const milliseconds = Number(resetAt);
    if (!Number.isFinite(milliseconds) || milliseconds <= 0) return "重置时间暂不可用";
    const date = new Date(milliseconds);
    return "重置于 " + date.toLocaleString("zh-CN", {
      month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit"
    });
  }

  function applyUsageAlert(valueId, barId, remainingPercent) {
    const isAlert = remainingPercent !== null && remainingPercent <= usageAlertThresholdPercent;
    byId(valueId).classList.toggle("usage-alert", isAlert);
    byId(barId).classList.toggle("usage-alert", isAlert);
  }

  function setWindow(prefix, data) {
    if (!data || typeof data !== "object") {
      byId(prefix).textContent = "—";
      byId(prefix + "Bar").style.width = "0%";
      applyUsageAlert(prefix, prefix + "Bar", null);
      if (byId(prefix + "Reset")) byId(prefix + "Reset").textContent = "用量数据暂不可用";
      return;
    }
    const usedPercent = Math.max(0, Math.min(100, Number(data.usedPercent) || 0));
    const remainingPercent = Math.round(100 - usedPercent);
    byId(prefix).textContent = remainingPercent + "%";
    byId(prefix + "Bar").style.width = remainingPercent + "%";
    applyUsageAlert(prefix, prefix + "Bar", remainingPercent);
    if (byId(prefix + "Reset")) byId(prefix + "Reset").textContent = resetText(data.resetAt);
  }

  function setWindowDetail(id, barId, resetId, data) {
    const target = byId(id);
    if (!data || typeof data !== "object") {
      target.textContent = "—";
      byId(barId).style.width = "0%";
      applyUsageAlert(id, barId, null);
      byId(resetId).textContent = "用量数据暂不可用";
      return;
    }
    const usedPercent = Math.max(0, Math.min(100, Number(data.usedPercent) || 0));
    const remainingPercent = Math.round(100 - usedPercent);
    target.textContent = remainingPercent + "%";
    byId(barId).style.width = remainingPercent + "%";
    applyUsageAlert(id, barId, remainingPercent);
    byId(resetId).textContent = resetText(data.resetAt);
  }

  function setTokenStats(prefix, tokens) {
    const available = tokens && tokens.available === true;
    const fields = [
      ["Input", "inputTokens"], ["Cache", "cacheReadTokens"],
      ["Output", "outputTokens"], ["Total", "totalTokens"]
    ];
    for (const [suffix, key] of fields) {
      const element = byId(prefix + suffix);
      if (element) element.textContent = available ? tokenNumber(tokens[key]) : "—";
    }
    return available;
  }

  function render(snapshot) {
    if (!snapshot) return;
    latestSnapshot = snapshot;
    if (snapshot.tools) setToolAvailability(snapshot.tools);
    const codex = snapshot.codex || {};
    const deepseek = snapshot.deepseek || {};
    const primary = codex.primary || null;
    const weekly = codex.weekly || null;
    const signedIn = deepseek.signedIn === true;

    setWindow("codexPrimary", primary);
    setWindow("codexWeekly", weekly);
    setWindow("miniPrimary", primary);
    setWindow("miniWeekly", weekly);
    setWindowDetail("detailPrimary", "detailPrimaryBar", "detailPrimaryReset", primary);
    setWindowDetail("detailWeekly", "detailWeeklyBar", "detailWeeklyReset", weekly);

    const codexSource = codex.source === "live" ? "ChatGPT 官方接口"
      : codex.source === "session" ? "本机会话回退" : "未连接";
    byId("codexSource").textContent = codexSource;
    byId("codexDetailSource").textContent = codexSource;
    const plan = [codex.planType, codex.email].filter(Boolean).join(" · ");
    byId("codexAccount").textContent = plan || "ChatGPT 用量";
    byId("codexPlan").textContent = codex.source === "session"
      ? "最近的本机 Codex 会话快照"
      : "读取当前 ChatGPT 登录态";
    byId("codexNote").textContent = codex.error || "用量来自当前 Codex 登录态；接口故障时使用最近的本机会话快照。";
    byId("codexDetailNote").textContent = codex.source === "live"
      ? "当前窗口数据来自 ChatGPT 用量接口。"
      : "Host 端使用本机 Codex 登录凭据请求 ChatGPT 用量接口。接口不可用时，会读取最近的本地会话记录。";
    byId("codexError").textContent = codex.error || "";

    const profile = deepseek.profile && typeof deepseek.profile === "object" ? deepseek.profile : {};
    byId("deepseekAccount").textContent = signedIn
      ? (profile.name || profile.contact || "DeepSeek 开放平台账户")
      : "尚未连接 DeepSeek 账户";
    byId("deepSeekLogin").hidden = signedIn;
    byId("deepSeekLoginDetail").hidden = signedIn;
    byId("deepSeekLoginSettings").hidden = signedIn;
    byId("deepSeekLogout").hidden = !signedIn;
    byId("deepSeekLogoutDetail").hidden = !signedIn;

    const balance = deepseek.balanceAvailable ? groupedAmounts(deepseek.balances) : null;
    const spend = deepseek.officialSpendAvailable ? groupedAmounts(deepseek.officialSpend) : null;
    const balanceText = signedIn ? (balance || "官方余额暂不可用") : "—";
    const spendText = signedIn ? (spend || "官方金额暂不可用") : "—";
    byId("deepSeekBalance").textContent = balanceText;
    byId("deepSeekSpend").textContent = spendText;
    byId("miniBalance").textContent = balanceText;
    byId("miniSpend").textContent = spendText;
    byId("detailBalance").textContent = balanceText;
    byId("detailSpend").textContent = spendText;
    const deepSeekBalanceAlert = signedIn && deepSeekBalanceIsAtOrBelowAlert(deepseek);
    for (const id of ["deepSeekBalance", "miniBalance", "detailBalance"]) {
      byId(id).classList.toggle("usage-alert", deepSeekBalanceAlert);
    }
    byId("deepSeekStatus").textContent = signedIn
      ? (deepseek.error || "官方账户已连接")
      : "连接官方账户后读取余额与累计金额";

    const tokens = deepseek.tokens || {};
    const hasTokens = setTokenStats("token", tokens);
    setTokenStats("deepToken", tokens);
    byId("tokenSource").textContent = hasTokens ? "本机记录" : "暂不可用";
    byId("deepSeekTokenSource").textContent = hasTokens ? "本机记录" : "暂不可用";
    const sessions = Number(tokens.sessions) || 0;
    const sessionText = hasTokens
      ? "已统计 " + fmt.format(sessions) + " 个本机会话"
      : "未检测到本机 DeepSeek 会话投影";
    byId("sessionCount").textContent = sessionText;
    byId("deepSessionCount").textContent = sessionText;
    if (hasTokens) {
      const total = tokenNumber(tokens.totalTokens);
      byId("sessionCount").textContent += " · 合计 " + total + " tokens";
      byId("deepSessionCount").textContent += " · 合计 " + total + " tokens";
    }

    byId("lastUpdated").textContent = snapshot.updatedAt
      ? "更新于 " + new Date(snapshot.updatedAt).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
      : "等待数据";
  }

  function showNotice(payload) {
    const banner = byId("notice");
    banner.textContent = payload.text || "";
    banner.classList.toggle("error", payload.isError === true);
    banner.classList.toggle("visible", Boolean(payload.text));
    clearTimeout(noticeTimer);
    if (payload.text) noticeTimer = setTimeout(() => banner.classList.remove("visible"), 5200);
  }

  function setHUDEnabled(enabled, visible) {
    byId("hudToggle").checked = enabled;
    byId("hudToggleSettings").checked = enabled;
    const status = !enabled ? "HUD 已关闭" : visible ? "HUD 显示中" : "HUD 窗口未显示";
    byId("hudVisibilityStatus").textContent = status;
    byId("hudVisibilitySettings").textContent = status;
  }

  function setToolAvailability(tools) {
    const codex = tools && tools.codex === true;
    const deepseek = tools && tools.deepseek === true;
    const hasAny = codex || deepseek;
    document.querySelectorAll("[data-tool='codex']").forEach((element) => {
      element.hidden = !codex;
    });
    document.querySelectorAll("[data-tool='deepseek']").forEach((element) => {
      element.hidden = !deepseek;
    });
    const accountGrid = byId("overviewAccounts");
    accountGrid.hidden = !hasAny;
    accountGrid.classList.toggle("single-tool", codex !== deepseek);
    byId("lowerGrid").hidden = !hasAny;
    byId("lowerGrid").classList.toggle("single-tool", codex !== deepseek);
    byId("noToolsEmpty").hidden = hasAny;
    byId("hudTopControl").hidden = !hasAny;
    byId("hudSettingsRow").hidden = !hasAny;
    byId("overviewDescription").textContent = codex && deepseek
      ? "Codex 与 DeepSeek 的官方账户状态和本机 Token 统计"
      : codex ? "Codex 账户的 5 小时与每周用量"
      : deepseek ? "DeepSeek 官方账户金额和本机 Token 统计"
      : "本机未检测到受支持的工具";
    const activePage = document.querySelector(".page.view-active");
    if (activePage && activePage.dataset.tool
        && ((activePage.dataset.tool === "codex" && !codex)
          || (activePage.dataset.tool === "deepseek" && !deepseek))) {
      setView("overview");
    }
  }

  function setUsageAlertThreshold(value) {
    const parsed = Number(value);
    if (!Number.isFinite(parsed)) return;
    usageAlertThresholdPercent = Math.min(100, Math.max(0, Math.round(parsed)));
    const input = byId("usageAlertThreshold");
    if (input) input.value = String(usageAlertThresholdPercent);
    if (latestSnapshot) render(latestSnapshot);
  }

  function setDeepSeekBalanceAlert(threshold, currency) {
    const parsed = Number(threshold);
    if (!Number.isFinite(parsed)) return;
    deepSeekBalanceAlertThreshold = Math.max(0, parsed);
    deepSeekBalanceAlertCurrency = currency === "USD" ? "USD" : "CNY";
    const amountInput = byId("deepSeekBalanceAlertThreshold");
    if (amountInput) amountInput.value = String(deepSeekBalanceAlertThreshold);
    const currencyInput = byId("deepSeekBalanceAlertCurrency");
    if (currencyInput) currencyInput.value = deepSeekBalanceAlertCurrency;
    if (latestSnapshot) render(latestSnapshot);
  }

  function setView(name) {
    document.querySelectorAll("[data-page]").forEach((page) => {
      page.classList.toggle("view-active", page.dataset.page === name);
    });
    document.querySelectorAll("[data-view]").forEach((button) => {
      button.classList.toggle("active", button.dataset.view === name);
    });
    const labels = { overview: "概览", codex: "Codex", deepseek: "DeepSeek", settings: "设置" };
    byId("crumb").textContent = labels[name] || "概览";
  }

  document.querySelectorAll("[data-view]").forEach((button) => {
    button.addEventListener("click", () => setView(button.dataset.view));
  });
  byId("refreshButton").addEventListener("click", () => native("refresh"));
  byId("deepSeekLogin").addEventListener("click", () => native("loginDeepSeek"));
  byId("deepSeekLoginDetail").addEventListener("click", () => native("loginDeepSeek"));
  byId("deepSeekLoginSettings").addEventListener("click", () => native("loginDeepSeek"));
  byId("deepSeekLogout").addEventListener("click", () => native("logoutDeepSeek"));
  byId("deepSeekLogoutDetail").addEventListener("click", () => native("logoutDeepSeek"));
  byId("openDeepSeekUsage").addEventListener("click", () => native("openUsage"));
  byId("openDeepSeekUsageDetail").addEventListener("click", () => native("openUsage"));
  byId("openDeepSeekTopUp").addEventListener("click", () => native("openTopUp"));
  byId("openDeepSeekTopUpDetail").addEventListener("click", () => native("openTopUp"));
  for (const toggle of [byId("hudToggle"), byId("hudToggleSettings")]) {
    toggle.addEventListener("change", () => native("toggleHUD", { enabled: toggle.checked }));
  }
  byId("usageAlertThreshold").addEventListener("change", (event) => {
    const input = event.currentTarget;
    if (input.value.trim() === "") {
      input.value = String(usageAlertThresholdPercent);
      return;
    }
    const parsed = Number(input.value);
    if (!Number.isFinite(parsed)) {
      input.value = String(usageAlertThresholdPercent);
      return;
    }
    const threshold = Math.min(100, Math.max(0, Math.round(parsed)));
    setUsageAlertThreshold(threshold);
    native("setUsageAlertThreshold", { value: threshold });
  });
  const commitDeepSeekBalanceAlert = () => {
    const amountInput = byId("deepSeekBalanceAlertThreshold");
    if (amountInput.value.trim() === "") {
      amountInput.value = String(deepSeekBalanceAlertThreshold);
      return;
    }
    const parsed = Number(amountInput.value);
    if (!Number.isFinite(parsed)) {
      amountInput.value = String(deepSeekBalanceAlertThreshold);
      return;
    }
    const threshold = Math.max(0, parsed);
    const currency = byId("deepSeekBalanceAlertCurrency").value;
    setDeepSeekBalanceAlert(threshold, currency);
    native("setDeepSeekBalanceAlert", { threshold, currency });
  };
  byId("deepSeekBalanceAlertThreshold").addEventListener("change", commitDeepSeekBalanceAlert);
  byId("deepSeekBalanceAlertCurrency").addEventListener("change", commitDeepSeekBalanceAlert);

  window.AAAAAUsage = {
    render, notice: showNotice, setHUDEnabled, setUsageAlertThreshold,
    setDeepSeekBalanceAlert, setToolAvailability
  };
}());
