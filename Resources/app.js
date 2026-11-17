(function () {
  "use strict";

  const fmt = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 });
  const integerFormatter = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 0 });
  const byId = (id) => document.getElementById(id);
  let usageAlertThresholdPercent = 20;
  let kimiMonthlyAlertThresholdPercent = 20;
  let deepSeekBalanceAlertThreshold = 10;
  let deepSeekBalanceAlertCurrency = "CNY";
  let autoRefreshEnabled = true;
  let latestSnapshot = null;
  let enabledToolSettings = { codex: false, deepseek: false, kimi: false };
  let detectedToolAvailability = { codex: false, deepseek: false, kimi: false };
  let currentView = "overview";
  const modelViews = ["codex", "deepseek", "kimi"];
  let modelHUDVisibility = {
    codex: { globalHUD: true, menuBarHUD: true },
    deepseek: { globalHUD: true, menuBarHUD: true },
    kimi: { globalHUD: true, menuBarHUD: true }
  };
  let activeModel = "codex";
  let detailRequestSequence = 0;
  let pendingDetailRequest = null;
  let lastSessionTrigger = null;

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

  function applyUsageAlert(valueId, barId, remainingPercent, threshold = usageAlertThresholdPercent) {
    const isAlert = remainingPercent !== null && remainingPercent <= threshold;
    byId(valueId).classList.toggle("usage-alert", isAlert);
    byId(barId).classList.toggle("usage-alert", isAlert);
  }

  function kimiUsedPercent(monthly) {
    if (!monthly || typeof monthly !== "object") return null;
    const normalized = monthly.usedPercent;
    if (normalized !== undefined && normalized !== null && normalized !== "") {
      const percent = Number(normalized);
      return Number.isFinite(percent) && percent >= 0 && percent <= 100 ? percent : null;
    }
    for (const key of ["amountUsedRatio", "amount_used_ratio", "usedRatio", "used_ratio", "ratio"]) {
      const raw = monthly[key];
      if (raw === undefined || raw === null || raw === "") continue;
      const ratio = Number(raw);
      if (!Number.isFinite(ratio) || ratio < 0 || ratio > 100) continue;
      return ratio <= 1 ? ratio * 100 : ratio;
    }
    return null;
  }

  function setWindow(prefix, data, highlightLow = true, threshold = usageAlertThresholdPercent) {
    const kimiPercent = prefix === "kimiMonthly" ? kimiUsedPercent(data) : null;
    if (!data || typeof data !== "object" || (prefix === "kimiMonthly" && kimiPercent === null)) {
      byId(prefix).textContent = "—";
      byId(prefix + "Bar").style.width = "0%";
      if (highlightLow) applyUsageAlert(prefix, prefix + "Bar", null);
      else {
        byId(prefix).classList.remove("usage-alert");
        byId(prefix + "Bar").classList.remove("usage-alert");
      }
      if (byId(prefix + "Reset")) byId(prefix + "Reset").textContent = "用量数据暂不可用";
      return;
    }
    const usedPercent = prefix === "kimiMonthly"
      ? kimiPercent
      : Math.max(0, Math.min(100, Number(data.usedPercent) || 0));
    const remainingPercent = Math.round(100 - usedPercent);
    byId(prefix).textContent = remainingPercent + "%";
    byId(prefix + "Bar").style.width = remainingPercent + "%";
    if (highlightLow) applyUsageAlert(prefix, prefix + "Bar", remainingPercent, threshold);
    else {
      byId(prefix).classList.remove("usage-alert");
      byId(prefix + "Bar").classList.remove("usage-alert");
    }
    if (byId(prefix + "Reset")) byId(prefix + "Reset").textContent = resetText(data.resetAt);
  }

  function setWindowDetail(id, barId, resetId, data, highlightLow = true, threshold = usageAlertThresholdPercent) {
    const target = byId(id);
    if (!data || typeof data !== "object") {
      target.textContent = "—";
      byId(barId).style.width = "0%";
      if (highlightLow) applyUsageAlert(id, barId, null);
      else {
        target.classList.remove("usage-alert");
        byId(barId).classList.remove("usage-alert");
      }
      byId(resetId).textContent = "用量数据暂不可用";
      return;
    }
    const usedPercent = Math.max(0, Math.min(100, Number(data.usedPercent) || 0));
    const remainingPercent = Math.round(100 - usedPercent);
    target.textContent = remainingPercent + "%";
    byId(barId).style.width = remainingPercent + "%";
    if (highlightLow) applyUsageAlert(id, barId, remainingPercent, threshold);
    else {
      target.classList.remove("usage-alert");
      byId(barId).classList.remove("usage-alert");
    }
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

  function updateModelTokenPanel(prefix, tokens, sourceId, noteId, sourceLabel) {
    const available = setTokenStats(prefix, tokens);
    const sourceElement = byId(sourceId);
    const noteElement = byId(noteId);
    if (!sourceElement || !noteElement) return available;
    sourceElement.classList.toggle("unavailable", !available);
    if (available) {
      sourceElement.textContent = sourceLabel;
      const sessions = fmt.format(Number(tokens.sessions) || 0);
      noteElement.textContent = `${tokens.source || "本机记录"} · ${sessions} 个会话 · 合计 ${tokenNumber(tokens.totalTokens)} tokens`;
    } else {
      const reason = tokens && tokens.reason ? tokens.reason : "";
      sourceElement.textContent = /不提供|未提供/.test(reason) ? "接口未提供" : "暂无记录";
      noteElement.textContent = reason || "未检测到本机 Token 记录";
    }
    return available;
  }

  function updateKimiMembershipPanel(kimi) {
    const monthly = kimi && kimi.monthly && typeof kimi.monthly === "object" ? kimi.monthly : null;
    const usedPercent = kimiUsedPercent(monthly);
    const available = usedPercent !== null;
    const source = byId("kimiTokenSource");
    const grid = byId("kimiTokenGrid");
    byId("kimiTokenTitle").textContent = "会员额度消耗";
    source.textContent = available ? "会员接口" : "额度不可用";
    source.classList.toggle("unavailable", !available);
    grid.replaceChildren();
    const used = available ? Math.round(usedPercent) : null;
    const details = available
      ? [["本月已用", String(used) + "%"], ["本月剩余", String(100 - used) + "%"],
         ["下次刷新", monthly.resetAt ? formatSessionTime(monthly.resetAt) : "时间暂不可用"]]
      : [["本月已用", "—"], ["本月剩余", "—"], ["下次刷新", "—"]];
    for (const [labelText, valueText] of details) {
      const item = document.createElement("div");
      item.className = "model-token-item";
      const label = document.createElement("span");
      label.textContent = labelText;
      const valueElement = document.createElement("strong");
      valueElement.textContent = valueText;
      item.append(label, valueElement);
      grid.appendChild(item);
    }
    byId("kimiTokenNote").textContent = available
      ? "Kimi 按 Token 消耗扣除会员额度；接口返回额度比例，不提供输入、缓存、输出 Token 数量。逐次使用记录可在 Kimi「设置 → 订阅」查看。"
      : (kimi && kimi.error) || "当前无法读取 Kimi 会员月额度。";
  }

  function formatSessionTime(value) {
    if (value === undefined || value === null || value === "") return "时间未知";
    const raw = Number(value);
    const date = new Date(Number.isFinite(raw) && raw > 0 ? (raw < 100000000000 ? raw * 1000 : raw) : value);
    if (Number.isNaN(date.getTime())) return String(value);
    return date.toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
  }

  function tokenValues(tokens) {
    const available = tokens && tokens.available === true;
    return [
      ["输入", available ? tokenNumber(tokens.inputTokens) : "—", "inputTokens"],
      ["缓存输入", available ? tokenNumber(tokens.cacheReadTokens) : "—", "cacheReadTokens"],
      ["输出", available ? tokenNumber(tokens.outputTokens) : "—", "outputTokens"],
      ["合计", available ? tokenNumber(tokens.totalTokens) : "—", "totalTokens"]
    ];
  }

  function renderModelPage(snapshot) {
    if (!snapshot) return;
    updateModelHUDControls();
    const model = snapshot[activeModel] || {};
    const isChatGPT = activeModel === "codex";
    const isDeepSeek = activeModel === "deepseek";
    const isKimi = activeModel === "kimi";
    const name = isChatGPT ? "ChatGPT" : isDeepSeek ? "DeepSeek" : "Kimi";
    const config = {
      codex: { eyebrow: "CHATGPT ACCOUNT", icon: "chatgpt-icon.png", appLabel: "打开 ChatGPT" },
      deepseek: { eyebrow: "DEEPSEEK ACCOUNT", icon: "deepseek-icon.png", appLabel: "打开 DSH" },
      kimi: { eyebrow: "KIMI MEMBERSHIP", icon: "kimi-icon.png", appLabel: "打开 Kimi" }
    }[activeModel];
    byId("modelPageEyebrow").textContent = config.eyebrow;
    byId("modelPageIcon").src = config.icon;
    byId("modelPageTitle").textContent = name + " 用量";
    byId("modelOpenApp").textContent = config.appLabel;

    const usageMetrics = byId("modelUsageMetrics");
    usageMetrics.replaceChildren();
    const metrics = [];
    if (isChatGPT) {
      const windows = [["5 小时剩余", model.primary], ["每周剩余", model.weekly]];
      for (const [label, window] of windows) {
        if (!window || typeof window !== "object") {
          metrics.push({ label, value: "—", note: "用量数据暂不可用", progress: null });
          continue;
        }
        const usedPercent = Math.max(0, Math.min(100, Number(window.usedPercent) || 0));
        metrics.push({ label, value: Math.round(100 - usedPercent) + "%", note: resetText(window.resetAt), progress: 100 - usedPercent });
      }
      byId("modelPageDescription").textContent = "ChatGPT 账户剩余用量、Token 明细与本机对话会话";
      byId("modelPageSource").textContent = model.source === "live" ? "ChatGPT 官方接口" : model.source === "session" ? "本机会话回退" : "等待数据";
      byId("modelUsageFoot").textContent = "额度来自 ChatGPT 用量接口；Token 统计和会话内容读取本机 Codex 会话记录。";
    } else if (isDeepSeek) {
      const balance = model.balanceAvailable ? groupedAmounts(model.balances) : null;
      const spend = model.officialSpendAvailable ? groupedAmounts(model.officialSpend) : null;
      metrics.push({ label: "账户余额", value: balance || "官方余额暂不可用", note: "DeepSeek 开放平台", money: true });
      metrics.push({ label: "累计消费", value: spend || "官方金额暂不可用", note: "官方账户摘要", money: true });
      byId("modelPageDescription").textContent = "官方账户金额、本机 Token 明细与 DeepSeek Harness 会话";
      byId("modelPageSource").textContent = model.credentialAvailable ? "官方账户 · 本机 Harness" : "本机 Harness 数据源未检测到";
      byId("modelUsageFoot").textContent = model.credentialAvailable
        ? "余额和累计消费读取官方账户摘要；Token 与会话记录来自本机 Harness。"
        : "未检测到本机 Harness 账户数据源；本机历史会话若可读仍会列在下方。";
    } else {
      const monthly = model.monthly;
      const usedPercent = kimiUsedPercent(monthly);
      if (usedPercent !== null) {
        metrics.push({ label: "会员月额度剩余", value: Math.round(100 - usedPercent) + "%", note: resetText(monthly.resetAt), progress: 100 - usedPercent, kimi: true });
      } else {
        metrics.push({ label: "会员月额度剩余", value: "—", note: model.error || "月额度数据暂不可用", progress: null, kimi: true });
      }
      byId("modelPageDescription").textContent = "Kimi 会员月额度、Token 明细与可读取的对话会话";
      byId("modelPageSource").textContent = model.available ? "Kimi 桌面会话" : model.sessionDetected ? "本机会话需要续期" : "等待 Kimi 会话";
      byId("modelUsageFoot").textContent = "Kimi 会员额度按月统计；此页面不显示 5 小时限额。";
    }
    usageMetrics.classList.toggle("single", metrics.length === 1);
    for (const item of metrics) {
      const metric = document.createElement("div");
      metric.className = "unified-usage-metric";
      const label = document.createElement("span");
      label.textContent = item.label;
      const valueElement = document.createElement("strong");
      valueElement.textContent = item.value;
      if (item.money) valueElement.classList.add("money");
      if (item.kimi) valueElement.classList.toggle("usage-alert", item.progress !== null && item.progress <= kimiMonthlyAlertThresholdPercent);
      if (item.progress !== null && item.progress !== undefined && !item.money) {
        const progress = document.createElement("div");
        progress.className = "progress" + (item.kimi && item.progress <= kimiMonthlyAlertThresholdPercent ? " kimi-progress" : "");
        progress.setAttribute("role", "progressbar");
        progress.setAttribute("aria-label", item.label);
        progress.setAttribute("aria-valuenow", String(Math.round(item.progress)));
        progress.setAttribute("aria-valuemin", "0");
        progress.setAttribute("aria-valuemax", "100");
        const bar = document.createElement("i");
        bar.style.width = item.progress + "%";
        progress.appendChild(bar);
        metric.append(label, valueElement, progress);
      } else {
        metric.append(label, valueElement);
      }
      const note = document.createElement("small");
      note.textContent = item.note;
      metric.appendChild(note);
      usageMetrics.appendChild(metric);
    }

    if (isDeepSeek) {
      const alert = model.credentialAvailable && deepSeekBalanceIsAtOrBelowAlert(model);
      usageMetrics.querySelectorAll(".unified-usage-metric strong.money").forEach((element) => element.classList.toggle("usage-alert", alert));
    }

    const tokens = model.tokens || {};
    if (!isKimi) {
      byId("modelTokenEyebrow").textContent = "TOKEN DETAILS";
      byId("modelTokenTitle").textContent = "Token 详情";
    }
    const tokenSource = byId("modelTokenSource");
    tokenSource.classList.toggle("unavailable", tokens.available !== true);
    tokenSource.textContent = tokens.available === true ? "本机记录"
      : (/不提供|未提供/.test(tokens.reason || "") ? "接口未提供" : "暂无记录");
    const tokenGrid = byId("modelTokenGrid");
    tokenGrid.replaceChildren();
    for (const [labelText, numberText, key] of tokenValues(tokens)) {
      const row = document.createElement("div");
      row.className = "unified-token-item" + (key === "totalTokens" ? " total" : "");
      const label = document.createElement("span");
      label.textContent = labelText;
      const number = document.createElement("strong");
      number.textContent = numberText;
      row.append(label, number);
      tokenGrid.appendChild(row);
    }
    const tokenCount = Number(tokens.sessions) || 0;
    byId("modelTokenFoot").textContent = tokens.available === true
      ? `${tokens.source || "本机记录"} · ${fmt.format(tokenCount)} 个会话 · 合计 ${tokenNumber(tokens.totalTokens)} tokens`
      : (tokens.reason || "当前数据源未提供 Token 分项统计");

    if (isKimi) {
      const monthly = model.monthly && typeof model.monthly === "object" ? model.monthly : null;
      const usedPercent = kimiUsedPercent(monthly);
      const hasMonthly = usedPercent !== null;
      byId("modelTokenEyebrow").textContent = "MEMBERSHIP USAGE";
      byId("modelTokenTitle").textContent = "会员额度消耗";
      tokenSource.classList.toggle("unavailable", !hasMonthly);
      tokenSource.textContent = hasMonthly ? "会员接口" : "额度不可用";
      tokenGrid.replaceChildren();
      const used = hasMonthly ? Math.round(usedPercent) : null;
      const details = hasMonthly
        ? [["本月已用", String(used) + "%"], ["本月剩余", String(100 - used) + "%"],
           ["下次刷新", monthly.resetAt ? formatSessionTime(monthly.resetAt) : "时间暂不可用"]]
        : [["本月已用", "—"], ["本月剩余", "—"], ["下次刷新", "—"]];
      for (const [labelText, numberText] of details) {
        const row = document.createElement("div");
        row.className = "unified-token-item";
        const label = document.createElement("span");
        label.textContent = labelText;
        const number = document.createElement("strong");
        number.textContent = numberText;
        row.append(label, number);
        tokenGrid.appendChild(row);
      }
      byId("modelTokenFoot").textContent = hasMonthly
        ? "Kimi 会员额度按 Token 消耗扣除；接口仅返回额度比例，不提供输入、缓存、输出 Token 数量。逐次使用记录可在 Kimi「设置 → 订阅」查看。"
        : model.error || "当前无法读取 Kimi 会员月额度。";
    }

    const sessions = Array.isArray(model.sessions) ? model.sessions : [];
    const sessionRows = byId("modelSessionRows");
    sessionRows.replaceChildren();
    const totalSessions = Math.max(sessions.length, Number(tokens.sessions) || 0);
    byId("modelSessionCount").textContent = sessions.length
      ? (totalSessions > sessions.length ? `最近 ${sessions.length} 条 · 共 ${fmt.format(totalSessions)} 个` : `${sessions.length} 个会话`)
      : "暂无会话";
    byId("modelSessionsDescription").textContent = model.sessionsReason
      || "按最近活动时间排列 · 点击一条查看发送内容和模型回复";
    if (!sessions.length) {
      const empty = document.createElement("div");
      empty.className = "unified-session-empty";
      empty.textContent = model.sessionsReason || "当前没有可展示的本机会话记录";
      sessionRows.appendChild(empty);
      return;
    }
    const labels = ["输入", "缓存输入", "输出", "合计"];
    for (const session of sessions) {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "unified-session-row";
      row.dataset.sessionId = String(session.id || "");
      row.dataset.updatedAt = String(session.updatedAt || "");
      row.setAttribute("aria-haspopup", "dialog");
      row.setAttribute("aria-label", "查看会话：" + (session.title || "未命名会话"));
      const main = document.createElement("span");
      main.className = "unified-session-main";
      const title = document.createElement("span");
      title.className = "unified-session-title";
      title.textContent = session.title || "未命名会话";
      const subtitle = document.createElement("span");
      subtitle.className = "unified-session-subtitle";
      subtitle.textContent = session.project || name;
      main.append(title, subtitle);
      const time = document.createElement("span");
      time.className = "unified-session-time";
      time.textContent = formatSessionTime(session.updatedAt);
      const tokenWrap = document.createElement("span");
      tokenWrap.className = "unified-session-tokens";
      const sessionTokens = session.tokens || {};
      const values = [sessionTokens.inputTokens, sessionTokens.cacheReadTokens, sessionTokens.outputTokens, sessionTokens.totalTokens];
      values.forEach((value, index) => {
        const token = document.createElement("span");
        token.className = "unified-session-token";
        token.textContent = session.tokensAvailable === false ? "—" : tokenNumber(value);
        const label = document.createElement("small");
        label.className = "unified-session-token-label";
        label.textContent = labels[index];
        token.appendChild(label);
        tokenWrap.appendChild(token);
      });
      const arrow = document.createElement("span");
      arrow.className = "unified-session-arrow";
      arrow.setAttribute("aria-hidden", "true");
      arrow.textContent = "›";
      row.append(main, time, tokenWrap, arrow);
      sessionRows.appendChild(row);
    }
  }

  function providerName(provider) {
    return provider === "codex" ? "ChatGPT" : provider === "deepseek" ? "DeepSeek" : "Kimi";
  }

  function showSessionDetail(session, trigger) {
    const overlay = byId("modelDetailOverlay");
    const requestId = String(++detailRequestSequence);
    pendingDetailRequest = requestId;
    lastSessionTrigger = trigger || null;
    byId("modelDetailTitle").textContent = session.title || "会话详情";
    byId("modelDetailSubtitle").textContent = (session.project || providerName(activeModel)) + " · " + formatSessionTime(session.updatedAt);
    byId("modelDetailMeta").textContent = providerName(activeModel) + " · Session " + (session.id || "");
    byId("modelDetailMessageCount").textContent = "";
    byId("modelDetailStatus").textContent = "正在读取本机对话记录…";
    byId("modelDetailMessages").replaceChildren();
    renderDetailTokens(session.tokens || {}, session.tokensAvailable !== false);
    overlay.hidden = false;
    byId("modelDetailClose").focus();
    native("loadSessionDetail", { provider: activeModel, sessionId: session.id, requestId });
  }

  function renderDetailTokens(tokens, available) {
    const grid = byId("modelDetailTokens");
    grid.replaceChildren();
    for (const [labelText, numberText, key] of tokenValues(Object.assign({}, tokens, { available }))) {
      const item = document.createElement("div");
      item.className = "session-detail-token" + (key === "totalTokens" ? " total" : "");
      const label = document.createElement("span");
      label.textContent = labelText;
      const number = document.createElement("strong");
      number.textContent = numberText;
      item.append(label, number);
      grid.appendChild(item);
    }
  }

  function receiveSessionDetail(data) {
    if (!data || String(data.requestId) !== pendingDetailRequest) return;
    pendingDetailRequest = null;
    if (data.error) {
      byId("modelDetailStatus").textContent = data.error;
      renderDetailTokens(data.tokens || {}, data.tokensAvailable === true);
      return;
    }
    byId("modelDetailTitle").textContent = data.title || "会话详情";
    byId("modelDetailSubtitle").textContent = (data.project || providerName(data.provider)) + " · " + formatSessionTime(data.updatedAt);
    byId("modelDetailMeta").textContent = providerName(data.provider) + " · Session " + (data.id || "");
    const messages = Array.isArray(data.messages) ? data.messages : [];
    byId("modelDetailMessageCount").textContent = messages.length ? `${messages.length} 条消息` : "无可展示内容";
    const container = byId("modelDetailMessages");
    container.replaceChildren();
    for (const message of messages) {
      const article = document.createElement("article");
      article.className = "session-message " + (message.role === "assistant" ? "assistant" : "user");
      const heading = document.createElement("div");
      heading.className = "session-message-heading";
      const role = document.createElement("strong");
      role.textContent = message.role === "assistant" ? providerName(data.provider) + " 回复" : "你发送的内容";
      const time = document.createElement("time");
      time.textContent = message.timestamp ? formatSessionTime(message.timestamp) : "";
      heading.append(role, time);
      const text = document.createElement("pre");
      text.className = "session-message-text";
      text.textContent = message.text || "";
      article.append(heading, text);
      container.appendChild(article);
    }
    byId("modelDetailStatus").textContent = messages.length
      ? "对话内容从本机 Session 记录读取；未展示内部推理或工具调用。"
      : "此会话记录中没有可展示的文字消息。";
    renderDetailTokens(data.tokens || {}, data.tokensAvailable === true);
  }

  function closeSessionDetail() {
    byId("modelDetailOverlay").hidden = true;
    byId("modelDetailMessages").replaceChildren();
    byId("modelDetailTokens").replaceChildren();
    byId("modelDetailMessageCount").textContent = "";
    pendingDetailRequest = null;
    if (lastSessionTrigger && document.contains(lastSessionTrigger)) lastSessionTrigger.focus();
    lastSessionTrigger = null;
  }

  function render(snapshot) {
    if (!snapshot) return;
    latestSnapshot = snapshot;
    if (snapshot.tools) setToolAvailability(snapshot.tools);
    const codex = snapshot.codex || {};
    const deepseek = snapshot.deepseek || {};
    const kimi = snapshot.kimi || {};
    const deepSeekCredentialAvailable = deepseek.credentialAvailable === true;

    setWindow("codexPrimary", codex.primary || null);
    setWindow("codexWeekly", codex.weekly || null);

    const monthly = kimi.monthly || null;
    setWindow("kimiMonthly", monthly, true, kimiMonthlyAlertThresholdPercent);
    const kimiSessionDetected = kimi.sessionDetected === true;
    byId("kimiAccount").textContent = kimi.available === true
      ? "Kimi 会员额度已读取"
      : kimiSessionDetected ? "本机会话已检测到，额度暂不可用" : "本机暂无可用会话";
    byId("kimiStatus").textContent = kimi.error || (kimi.available ? "Kimi 会员额度已更新" : "暂时无法读取 Kimi 额度");
    byId("kimiStatus").title = kimi.error || "Kimi 会员额度状态";

    const codexSource = codex.source === "live" ? "ChatGPT 官方接口"
      : codex.source === "session" ? "本机会话回退" : "未连接";
    byId("codexSource").textContent = codexSource;
    const plan = [codex.planType, codex.email].filter(Boolean).join(" · ");
    byId("codexAccount").textContent = plan || "ChatGPT 用量";
    updateModelTokenPanel(
      "chatgptToken", codex.tokens || {}, "chatgptTokenSource", "chatgptTokenNote", "本机记录"
    );

    const profile = deepseek.profile && typeof deepseek.profile === "object" ? deepseek.profile : {};
    byId("deepseekAccount").textContent = deepSeekCredentialAvailable
      ? (profile.name || profile.contact || "本机 Harness 数据源")
      : "未检测到本机 Harness 数据源";
    const balance = deepseek.balanceAvailable ? groupedAmounts(deepseek.balances) : null;
    const spend = deepseek.officialSpendAvailable ? groupedAmounts(deepseek.officialSpend) : null;
    byId("deepSeekBalance").textContent = deepSeekCredentialAvailable ? (balance || "官方余额暂不可用") : "—";
    byId("deepSeekSpend").textContent = deepSeekCredentialAvailable ? (spend || "官方金额暂不可用") : "—";
    byId("deepSeekBalance").classList.toggle("usage-alert", deepSeekCredentialAvailable && deepSeekBalanceIsAtOrBelowAlert(deepseek));
    const tokens = deepseek.tokens || {};
    updateModelTokenPanel("token", tokens, "tokenSource", "sessionCount", "本机记录");

    updateKimiMembershipPanel(kimi);
    if (modelViews.includes(currentView)) renderModelPage(snapshot);

    byId("lastUpdated").textContent = snapshot.updatedAt
      ? "更新于 " + new Date(snapshot.updatedAt).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
      : "等待数据";
  }

  function setHUDEnabled(enabled, visible) {
    byId("hudToggle").checked = enabled;
    byId("hudToggleSettings").checked = enabled;
    const status = !enabled ? "悬浮窗已关闭" : visible ? "悬浮窗显示中" : "悬浮窗未显示";
    byId("hudVisibilityStatus").textContent = status;
    byId("hudVisibilitySettings").textContent = status;
  }

  function setMenuBarHUDEnabled(enabled) {
    byId("menuBarHUDToggle").checked = enabled;
  }

  function setModelHUDVisibility(settings) {
    if (!settings || typeof settings !== "object") return;
    modelHUDVisibility = Object.fromEntries(modelViews.map((provider) => {
      const value = settings[provider] || {};
      return [provider, {
        globalHUD: value.globalHUD !== false,
        menuBarHUD: value.menuBarHUD !== false
      }];
    }));
    updateModelHUDControls();
  }

  function updateModelHUDControls() {
    const settings = modelHUDVisibility[activeModel] || {};
    byId("modelGlobalHUDToggle").checked = settings.globalHUD !== false;
    byId("modelMenuBarHUDToggle").checked = settings.menuBarHUD !== false;
  }

  function setHUDDisplays(displays) {
    const select = byId("hudDisplay");
    if (!select) return;
    const options = Array.isArray(displays) ? displays : [];
    select.replaceChildren();
    for (const display of options) {
      if (!display || !display.id) continue;
      const option = document.createElement("option");
      option.value = String(display.id);
      option.textContent = display.label || "显示器";
      option.selected = display.selected === true;
      select.appendChild(option);
    }
    select.disabled = options.length < 2;
  }

  function setToolAvailability(tools) {
    const codex = tools && tools.codex === true;
    const deepseek = tools && tools.deepseek === true;
    const kimi = tools && tools.kimi === true;
    const visibleCount = [codex, deepseek, kimi].filter(Boolean).length;
    const hasAny = visibleCount > 0;
    document.querySelectorAll("[data-tool='codex']").forEach((element) => {
      element.hidden = !codex;
    });
    document.querySelectorAll("[data-tool='deepseek']").forEach((element) => {
      element.hidden = !deepseek;
    });
    document.querySelectorAll("[data-tool='kimi']").forEach((element) => {
      element.hidden = !kimi;
    });
    const accountGrid = byId("overviewAccounts");
    accountGrid.hidden = !hasAny;
    byId("noToolsEmpty").hidden = hasAny;
    byId("refreshButton").hidden = !hasAny;
    byId("autoRefreshSetting").hidden = !hasAny;
    byId("hudTopControl").hidden = !hasAny;
    byId("menuBarHUDControl").hidden = !hasAny;
    byId("hudVisibilityStatus").hidden = !hasAny;
    byId("hudSettingsRow").hidden = !hasAny;
    byId("hudDisplayRow").hidden = !hasAny;
    byId("noToolsMessage").textContent = Object.values(enabledToolSettings).some(Boolean)
      ? "已开启的工具未检测到可用的本机数据源，请检查相关工具的安装或登录状态。"
      : "尚未启用任何工具。请在设置中开启要监控的工具。";
    byId("overviewDescription").textContent = codex && deepseek && kimi
      ? "各模型的剩余用量与本机 Token 使用情况"
      : codex && deepseek ? "ChatGPT 与 DeepSeek 的剩余用量和 Token 统计"
      : codex && kimi ? "ChatGPT 与 Kimi 的剩余用量和 Token 明细状态"
      : deepseek && kimi ? "DeepSeek 与 Kimi 的账户用量和 Token 明细状态"
      : codex ? "ChatGPT 账户的剩余用量与 Token 统计"
      : deepseek ? "DeepSeek 账户金额与本机 Token 统计"
      : kimi ? "Kimi 会员月额度与 Token 明细状态"
      : "当前没有启用且可用的工具";
    if (latestSnapshot && typeof latestSnapshot === "object") {
      const sanitized = Object.assign({}, latestSnapshot, { tools: { codex, deepseek, kimi } });
      if (!codex) delete sanitized.codex;
      if (!deepseek) delete sanitized.deepseek;
      if (!kimi) delete sanitized.kimi;
      latestSnapshot = sanitized;
    }
    if ((activeModel === "codex" && !codex)
        || (activeModel === "deepseek" && !deepseek)
        || (activeModel === "kimi" && !kimi)) {
      if (!byId("modelDetailOverlay").hidden) closeSessionDetail();
    }
    if ((currentView === "codex" && !codex)
        || (currentView === "deepseek" && !deepseek)
        || (currentView === "kimi" && !kimi)) {
      setView("overview");
    }
  }

  function setToolSettings(enabled, detected) {
    enabledToolSettings = Object.assign({ codex: false, deepseek: false, kimi: false }, enabled || {});
    detectedToolAvailability = Object.assign({ codex: false, deepseek: false, kimi: false }, detected || {});
    const settings = [
      ["codex", "toolEnabledCodex", "toolStatusCodex"],
      ["deepseek", "toolEnabledDeepSeek", "toolStatusDeepSeek"],
      ["kimi", "toolEnabledKimi", "toolStatusKimi"]
    ];
    for (const [tool, inputId, statusId] of settings) {
      const isEnabled = enabledToolSettings[tool] === true;
      const isDetected = detectedToolAvailability[tool] === true;
      byId(inputId).checked = isEnabled;
      byId(statusId).textContent = !isEnabled
        ? "已停用"
        : isDetected ? "已启用" : "已开启 · 未检测到";
    }
    if (byId("noToolsEmpty") && !byId("noToolsEmpty").hidden) {
      byId("noToolsMessage").textContent = Object.values(enabledToolSettings).some(Boolean)
        ? "已开启的工具未检测到可用的本机数据源，请检查相关工具的安装或登录状态。"
        : "尚未启用任何工具。请在设置中开启要监控的工具。";
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

  function setAutoRefreshEnabled(enabled) {
    autoRefreshEnabled = enabled === true;
    byId("autoRefreshToggle").checked = autoRefreshEnabled;
    byId("autoRefreshStatus").textContent = autoRefreshEnabled ? "已开启" : "已关闭";
  }

  function setKimiMonthlyAlertThreshold(value) {
    const parsed = Number(value);
    if (!Number.isFinite(parsed)) return;
    kimiMonthlyAlertThresholdPercent = Math.min(100, Math.max(0, Math.round(parsed)));
    const input = byId("kimiMonthlyAlertThreshold");
    if (input) input.value = String(kimiMonthlyAlertThresholdPercent);
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
    if (modelViews.includes(name)) activeModel = name;
    currentView = name;
    const pageName = modelViews.includes(name) ? "model" : name;
    document.querySelectorAll("[data-page]").forEach((page) => {
      page.classList.toggle("view-active", page.dataset.page === pageName);
    });
    document.querySelectorAll("[data-view]").forEach((button) => {
      button.classList.toggle("active", button.dataset.view === name);
    });
    const labels = { overview: "概览", codex: "ChatGPT", deepseek: "DeepSeek", kimi: "Kimi", settings: "设置" };
    byId("crumb").textContent = labels[name] || "概览";
    updateModelHUDControls();
    if (modelViews.includes(name)) {
      renderModelPage(latestSnapshot);
    } else {
      byId("modelSessionRows").replaceChildren();
    }
  }

  document.querySelectorAll("[data-view]").forEach((button) => {
    button.addEventListener("click", () => setView(button.dataset.view));
  });
  byId("modelSessionRows").addEventListener("click", (event) => {
    const row = event.target.closest(".unified-session-row");
    if (!row || !row.dataset.sessionId) return;
    showSessionDetail({ id: row.dataset.sessionId, title: row.querySelector(".unified-session-title")?.textContent,
      project: row.querySelector(".unified-session-subtitle")?.textContent, updatedAt: row.dataset.updatedAt }, row);
  });
  byId("modelDetailClose").addEventListener("click", closeSessionDetail);
  byId("modelDetailOverlay").addEventListener("click", (event) => {
    if (event.target === byId("modelDetailOverlay")) closeSessionDetail();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !byId("modelDetailOverlay").hidden) closeSessionDetail();
  });
  byId("refreshButton").addEventListener("click", () => native("refresh"));
  byId("openSettingsFromEmpty").addEventListener("click", () => setView("settings"));
  byId("autoRefreshToggle").addEventListener("change", (event) => {
    autoRefreshEnabled = event.currentTarget.checked;
    byId("autoRefreshStatus").textContent = autoRefreshEnabled ? "已开启" : "已关闭";
    native("setAutoRefreshEnabled", { enabled: autoRefreshEnabled });
  });
  for (const [tool, inputId] of [
    ["codex", "toolEnabledCodex"],
    ["deepseek", "toolEnabledDeepSeek"],
    ["kimi", "toolEnabledKimi"]
  ]) {
    byId(inputId).addEventListener("change", (event) => {
      native("setToolEnabled", { tool, enabled: event.currentTarget.checked });
    });
  }
  const connectKimi = () => native("openKimiAccount");
  byId("kimiConnect").addEventListener("click", connectKimi);
  const openChatGPT = () => native("openChatGPTApp");
  byId("openChatGPTApp").addEventListener("click", openChatGPT);
  const openDeepSeekHarness = () => native("openDeepSeekHarness");
  byId("openDeepSeekHarness").addEventListener("click", openDeepSeekHarness);
  byId("modelOpenApp").addEventListener("click", () => {
    if (activeModel === "codex") openChatGPT();
    else if (activeModel === "deepseek") openDeepSeekHarness();
    else connectKimi();
  });
  for (const toggle of [byId("hudToggle"), byId("hudToggleSettings")]) {
    toggle.addEventListener("change", () => native("toggleHUD", { enabled: toggle.checked }));
  }
  byId("menuBarHUDToggle").addEventListener("change", () => {
    native("toggleMenuBarHUD", { enabled: byId("menuBarHUDToggle").checked });
  });
  byId("modelGlobalHUDToggle").addEventListener("change", () => {
    native("setModelHUDVisibility", {
      provider: activeModel,
      surface: "globalHUD",
      enabled: byId("modelGlobalHUDToggle").checked
    });
  });
  byId("modelMenuBarHUDToggle").addEventListener("change", () => {
    native("setModelHUDVisibility", {
      provider: activeModel,
      surface: "menuBarHUD",
      enabled: byId("modelMenuBarHUDToggle").checked
    });
  });
  byId("hudDisplay").addEventListener("change", (event) => {
    native("moveHUDToDisplay", { displayID: event.currentTarget.value });
  });
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
  byId("kimiMonthlyAlertThreshold").addEventListener("change", (event) => {
    const input = event.currentTarget;
    if (input.value.trim() === "") {
      input.value = String(kimiMonthlyAlertThresholdPercent);
      return;
    }
    const parsed = Number(input.value);
    if (!Number.isFinite(parsed)) {
      input.value = String(kimiMonthlyAlertThresholdPercent);
      return;
    }
    const threshold = Math.min(100, Math.max(0, Math.round(parsed)));
    setKimiMonthlyAlertThreshold(threshold);
    native("setKimiMonthlyAlertThreshold", { value: threshold });
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
    render, setHUDEnabled, setMenuBarHUDEnabled, setModelHUDVisibility, setHUDDisplays, setUsageAlertThreshold, setKimiMonthlyAlertThreshold,
    setAutoRefreshEnabled,
    setDeepSeekBalanceAlert, setToolAvailability, setToolSettings, receiveSessionDetail
  };
}());
