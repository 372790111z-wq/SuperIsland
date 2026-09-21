"use strict";

const LOW_THRESHOLD = 25;
const VERY_LOW_THRESHOLD = 10;

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function colorForRemaining(remainingPercent) {
  if (remainingPercent <= VERY_LOW_THRESHOLD) return "red";
  if (remainingPercent <= LOW_THRESHOLD) return "orange";
  return "green";
}

function formatPercent(value) {
  return `${Math.round(clamp(value, 0, 100))}%`;
}

function percentLabel(value) {
  if (value === null || value === undefined) return "--%";
  return `${Math.round(clamp(value, 0, 100))}%`;
}

function sourceLabel(source) {
  switch (source) {
    case "oauth-api":
      return "OAuth API";
    case "local-summary":
      return "Local summary";
    case "auth-token":
      return "Auth token";
    case "stats-cache":
      return "Stats cache";
    case "unavailable":
      return "Unavailable";
    default:
      return null;
  }
}

function withSource(detail, source) {
  const sourceText = sourceLabel(source);
  if (!sourceText) return detail;
  return detail ? `${detail} | ${sourceText}` : sourceText;
}

function pickCodexWindow(codex) {
  return codexUsageWindows(codex).reduce((lowest, window) =>
    !lowest || window.remainingPercent < lowest.remainingPercent ? window : lowest, null);
}

function codexRemainingPercent(codexWindow) {
  if (!codexWindow) return null;

  const remaining = toNumber(codexWindow.remainingPercent, null);
  if (remaining !== null) return clamp(remaining, 0, 100);

  const used = toNumber(codexWindow.usedPercent, null);
  if (used !== null) return clamp(100 - used, 0, 100);

  return null;
}

function codexUsageStats(codex) {
  const windows = codexUsageWindows(codex);
  const session = windows.find(window => window.windowMinutes === 300);
  const weekly = windows.find(window => window.windowMinutes === 10080);
  return {
    weeklyRemaining: weekly ? Math.round(weekly.remainingPercent) : null,
    sessionRemaining: session ? Math.round(session.remainingPercent) : null
  };
}

function codexNumber(value) {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function codexUsageWindows(codex) {
  if (codex.available !== true) return [];
  return [codex.primary, codex.secondary].map(value => {
    const window = asObject(value);
    if (!window) return null;
    const used = codexNumber(window.usedPercent);
    const remaining = codexNumber(window.remainingPercent) ?? (used === null ? null : 100 - used);
    const minutes = codexNumber(window.windowMinutes);
    if (remaining === null || remaining < 0 || remaining > 100 || !Number.isInteger(minutes) || minutes <= 0) return null;
    const label = minutes === 10080 ? "每周剩余"
      : minutes % 60 === 0 ? `${minutes / 60} 小时剩余` : `${minutes} 分钟剩余`;
    return { remainingPercent: remaining, windowMinutes: minutes, windowLabel: label };
  }).filter(Boolean).sort((a, b) => a.windowMinutes - b.windowMinutes);
}

function codexStatus(codex) {
  if (codex.status === "stale") return "更新延迟";
  if (codex.status === "loading" || codex.source === "loading") return "读取中";
  switch (codex.errorCode) {
    case "auth": return "登录已失效，请重新登录 Codex";
    case "no-credentials": return "请先登录 Codex";
    case "timeout": return "请求超时，稍后重试";
    case "network": return "连接失败，稍后重试";
    case "rate-limited": return "刷新受限，稍后重试";
    case "invalid-response": return "用量数据异常，稍后重试";
    default: return codex.available === true ? "" : "暂时无法读取用量";
  }
}

function codexModel(usage) {
  const codex = asObject(usage && usage.codex) || {};
  const model = codexReadingModel(usage);
  model.windows = codexUsageWindows(codex);
  model.isStale = codex.status === "stale";
  model.status = codexStatus(codex) || (model.windows.length ? "" : "暂时无法读取用量");
  model.updatedAt = codexNumber(codex.updatedAt);
  return model;
}

function codexReadingModel(usage) {
  const codex = asObject(usage && usage.codex);
  const source = codex && typeof codex.source === "string" ? codex.source : null;
  if (!codex || codex.available !== true) {
    return {
      title: "Codex",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: null,
      sessionRemaining: null,
      detail: withSource("Not available", source)
    };
  }

  const window = pickCodexWindow(codex);
  const remaining = codexRemainingPercent(window);
  const usageStats = codexUsageStats(codex);

  if (remaining === null) {
    return {
      title: "Codex",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: usageStats.weeklyRemaining,
      sessionRemaining: usageStats.sessionRemaining,
      detail: withSource("No window data", source)
    };
  }

  return {
    title: "Codex",
    text: formatPercent(remaining),
    remaining,
    progress: remaining / 100,
    color: colorForRemaining(remaining),
    weeklyRemaining: usageStats.weeklyRemaining,
    sessionRemaining: usageStats.sessionRemaining,
    detail: withSource(window && window.windowLabel ? window.windowLabel : "Usage window", source)
  };
}

function claudeModel(usage) {
  const claude = asObject(usage && usage.claude);
  const source = claude && typeof claude.source === "string" ? claude.source : null;
  if (!claude || claude.available !== true) {
    return {
      title: "Claude",
      text: "--",
      remaining: 0,
      progress: 0,
      color: "gray",
      weeklyRemaining: null,
      sessionRemaining: null,
      detail: withSource("Not available", source)
    };
  }

  const status = typeof claude.status === "string" ? claude.status : "allowed";
  const statusLabel = typeof claude.statusLabel === "string" ? claude.statusLabel : null;
  const explicitRemaining = toNumber(claude.remainingPercent, null);
  const explicitWeeklyRemaining = toNumber(claude.weeklyRemainingPercent, null);
  const explicitSessionRemaining = toNumber(claude.currentSessionRemainingPercent, null);
  const hoursTillReset = toNumber(claude.hoursTillReset, null);

  let remaining;
  let detail;

  if (explicitRemaining !== null) {
    remaining = clamp(explicitRemaining, 0, 100);
    detail = statusLabel || "Usage data";
  } else if (status === "rejected") {
    remaining = 0;
    detail = statusLabel || "Blocked";
  } else if (status === "allowed_warning") {
    const warningLooksLow = statusLabel && /(low|limit|blocked|exceeded|critical)/i.test(statusLabel);
    if (warningLooksLow) {
      remaining = 20;
      detail = statusLabel || "Low remaining";
    } else if (hoursTillReset !== null) {
      if (hoursTillReset <= 1) {
        remaining = 8;
      } else if (hoursTillReset <= 3) {
        remaining = 22;
      } else {
        remaining = 55;
      }
      detail = statusLabel || `${Math.ceil(hoursTillReset)}h to reset`;
    } else {
      remaining = 55;
      detail = statusLabel || "Warning";
    }
  } else if (hoursTillReset !== null) {
    if (hoursTillReset <= 1) {
      remaining = 8;
    } else if (hoursTillReset <= 3) {
      remaining = 22;
    } else {
      remaining = 65;
    }
    detail = statusLabel || `${Math.ceil(hoursTillReset)}h to reset`;
  } else {
    remaining = 65;
    detail = statusLabel || "Available";
  }

  return {
    title: "Claude",
    text: formatPercent(remaining),
    remaining,
    progress: remaining / 100,
    color: colorForRemaining(remaining),
    weeklyRemaining: explicitWeeklyRemaining !== null ? Math.round(clamp(explicitWeeklyRemaining, 0, 100)) : null,
    sessionRemaining: explicitSessionRemaining !== null ? Math.round(clamp(explicitSessionRemaining, 0, 100)) : null,
    detail: withSource(detail, source)
  };
}

function ringWithPercent(model, lineWidth) {
  return View.hstack([
    View.circularProgress(model.progress, {
      total: 1,
      lineWidth,
      color: model.color
    }),
    View.text(model.text, {
      style: "monospacedSmall",
      color: model.color
    }),
    ...(model.isStale ? [View.text("延迟", { style: "caption", color: "orange" })] : [])
  ], { spacing: 5, align: "center" });
}

function codexStatusViews(model) {
  return model.status ? [View.text(model.status, {
    style: "footnote", color: model.isStale ? "orange" : "gray"
  })] : [];
}

function codexUpdatedViews(model) {
  if (!model.windows.length || model.updatedAt === null || model.updatedAt <= 0) return [];
  const date = new Date(model.updatedAt * 1000);
  if (!Number.isFinite(date.getTime())) return [];
  const time = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  return [View.text(`更新于 ${time}`, { style: "footnote", color: "gray" })];
}

function usageSnapshot() {
  const usage = SuperIsland.system.getAIUsage();
  return usage && typeof usage === "object" ? usage : null;
}

SuperIsland.registerModule({
  compact() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    return View.hstack([
      ringWithPercent(codex, 2.5),
      View.spacer(),
      ringWithPercent(claude, 2.5)
    ], { spacing: 8, align: "center" });
  },

  minimalCompact: {
    leading() {
      const usage = usageSnapshot();
      const codex = codexModel(usage);
      const ring = View.circularProgress(codex.progress, {
        total: 1,
        lineWidth: 3,
        color: codex.color
      });
      return codex.isStale ? View.hstack([
        ring, View.text("延迟", { style: "caption", color: "orange" })
      ], { spacing: 3, align: "center" }) : ring;
    },

    trailing() {
      const usage = usageSnapshot();
      const claude = claudeModel(usage);
      return View.frame(
        View.circularProgress(claude.progress, {
          total: 1,
          lineWidth: 3,
          color: claude.color
        }),
        { maxWidth: 1000, alignment: "trailing" }
      );
    }
  },

  expanded() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    return View.hstack([
      View.vstack([
        View.text("Codex", { style: "caption", color: "gray" }),
        View.hstack([
          View.circularProgress(codex.progress, { total: 1, lineWidth: 4, color: codex.color }),
          View.text(codex.text, { style: "monospaced", color: codex.color })
        ], { spacing: 8, align: "center" }),
        ...codexStatusViews(codex)
      ], { spacing: 4, align: "center" }),

      View.vstack([
        View.text("Claude", { style: "caption", color: "gray" }),
        View.hstack([
          View.circularProgress(claude.progress, { total: 1, lineWidth: 4, color: claude.color }),
          View.text(claude.text, { style: "monospaced", color: claude.color })
        ], { spacing: 8, align: "center" })
      ], { spacing: 4, align: "center" })
    ], { spacing: 12, align: "center", distribution: "fillEqually" });
  },

  fullExpanded() {
    const usage = usageSnapshot();
    const codex = codexModel(usage);
    const claude = claudeModel(usage);

    return View.vstack([
      View.text("AI 用量", { style: "title", color: "white" }),
      View.hstack([
        View.vstack([
          View.circularProgress(codex.progress, { total: 1, lineWidth: 6, color: codex.color }),
          View.text("Codex", { style: "caption", color: "gray" }),
          View.text(codex.text, { style: "monospaced", color: codex.color }),
          ...codex.windows.map(window => View.text(`${window.windowLabel} ${formatPercent(window.remainingPercent)}`, { style: "footnote", color: "gray" })),
          ...codexStatusViews(codex),
          ...codexUpdatedViews(codex)
        ], { spacing: 4, align: "center" }),
        View.vstack([
          View.circularProgress(claude.progress, { total: 1, lineWidth: 6, color: claude.color }),
          View.text("Claude", { style: "caption", color: "gray" }),
          View.text(claude.text, { style: "monospaced", color: claude.color }),
          View.text(`Week ${percentLabel(claude.weeklyRemaining)}`, { style: "footnote", color: "gray" }),
          View.text(`Session ${percentLabel(claude.sessionRemaining)}`, { style: "footnote", color: "gray" })
        ], { spacing: 4, align: "center" })
      ], { spacing: 20, align: "center", distribution: "fillEqually" })
    ], { spacing: 10, align: "center" });
  }
});
