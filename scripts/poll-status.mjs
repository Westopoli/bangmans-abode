// scripts/poll-status.mjs
//
// Runs in the GitHub Action every 5 min.
// 1. Fetch mcsrvstat.us status for the Java address.
// 2. Append a single line to data/playtime.jsonl with timestamp + online players.
// 3. Recompute data/playtime-summary.json for the site to consume.
//
// Design notes:
// - JSONL (one JSON object per line) for the raw log so we never re-parse on append.
// - Summary is a small file with everything the site needs pre-computed.
// - If mcsrvstat.us is down or rate-limits us, we record online: null and move on.
//   The site treats null samples as "we don't know" — they don't count as offline,
//   so a 30-min outage at the API doesn't accidentally end someone's session.

import fs from "node:fs";
import path from "node:path";

const SERVER = "bangmansabode.minekeep.gg";
const STATUS_URL = `https://api.mcsrvstat.us/3/${SERVER}`;
const DATA_DIR = "data";
const RAW_PATH = path.join(DATA_DIR, "playtime.jsonl");
const SUMMARY_PATH = path.join(DATA_DIR, "playtime-summary.json");

// One sample is "active enough" if it's within this many minutes of another sample.
// At a 5-min cron, two samples 5 min apart count as one continuous session.
// We allow up to 12 min of gap to absorb GitHub Action delays during high load.
const SESSION_GAP_MIN = 12;

// How many days of raw data the summary considers. Older samples stay in the JSONL
// (history is forever) but only this window contributes to weekly/recent stats.
const ACTIVE_WINDOW_DAYS = 30;

// ─── 1. Fetch status ────────────────────────────────────────────────────────
async function fetchStatus() {
  try {
    const r = await fetch(STATUS_URL, {
      headers: { "User-Agent": "BangmanPoller/1.0 (github actions)" },
      // mcsrvstat.us is usually fast; cap the wait so a stuck request can't hold the job.
      signal: AbortSignal.timeout(15_000),
    });
    if (!r.ok) return { ok: false, reason: `http ${r.status}` };
    const data = await r.json();
    return { ok: true, data };
  } catch (e) {
    return { ok: false, reason: e.message ?? String(e) };
  }
}

// ─── 2. Append one sample to the raw log ────────────────────────────────────
function appendSample(sample) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.appendFileSync(RAW_PATH, JSON.stringify(sample) + "\n");
}

// ─── 3. Recompute summary from all raw samples ──────────────────────────────
//
// Schema we produce:
//
// {
//   "updated_at": "2026-05-04T14:25:00Z",
//   "now_online": ["Bailey", "Mike"],          // currently-online players
//   "last_seen": { "Bailey": "...", ... },     // ISO timestamp last seen
//   "totals": {                                 // all-time totals (within ACTIVE_WINDOW)
//     "Bailey": { "minutes": 252, "sessions": 14, "longest_session_min": 78 },
//     ...
//   },
//   "this_week": {                              // last 7 days only
//     "Bailey": { "minutes": 41, "sessions": 3 },
//     ...
//   },
//   "activity_by_hour": [0,0,1,2,5,8,...],     // 24-len: total player-minutes per hour-of-day
//   "activity_by_dow":  [12, 4, 0, 0, 8, 30, 45], // 7-len: Sun..Sat player-minutes
//   "leaderboard": [                           // sorted by all-time minutes
//     { "name": "Bailey", "minutes": 252 },
//     ...
//   ]
// }
function buildSummary() {
  if (!fs.existsSync(RAW_PATH)) {
    return {
      updated_at: new Date().toISOString(),
      now_online: [],
      last_seen: {},
      totals: {},
      this_week: {},
      activity_by_hour: new Array(24).fill(0),
      activity_by_dow: new Array(7).fill(0),
      leaderboard: [],
    };
  }

  const lines = fs.readFileSync(RAW_PATH, "utf8").split("\n").filter(Boolean);
  const samples = [];
  for (const line of lines) {
    try { samples.push(JSON.parse(line)); } catch { /* skip malformed */ }
  }
  samples.sort((a, b) => a.t.localeCompare(b.t));

  const now = Date.now();
  const windowStart = now - ACTIVE_WINDOW_DAYS * 86_400_000;
  const weekStart   = now - 7              * 86_400_000;

  // Walk samples; track per-player session state.
  // A "session" is a contiguous run where the player appears in samples that are
  // no more than SESSION_GAP_MIN apart. Each minute between two consecutive
  // samples in a session counts toward that player's minutes.
  const lastSeenAt = new Map();   // name -> Date of last sample player was in
  const lastInSession = new Map(); // name -> Date of the previous "in" sample (for delta accumulation)
  const sessionStart = new Map(); // name -> Date when current session started

  const totals = {};      // all-time-within-window
  const thisWeek = {};    // last 7d
  const byHour = new Array(24).fill(0);
  const byDow  = new Array(7).fill(0);

  function ensureTotal(name) {
    if (!totals[name]) totals[name] = { minutes: 0, sessions: 0, longest_session_min: 0 };
    return totals[name];
  }
  function ensureWeek(name) {
    if (!thisWeek[name]) thisWeek[name] = { minutes: 0, sessions: 0 };
    return thisWeek[name];
  }

  // Session counting strategy: a session ends exactly when we observe a transition
  // from "player was in prevOnline" to "player not in current sample" (or via the
  // gap-too-large path, which is structurally the same — the previous appearance
  // was the end). We count the session at end-of-session, not at start, and we
  // close any still-open sessions at end-of-data.
  let prevOnline = new Set();

  for (const s of samples) {
    if (!s.online_players) continue; // null sample (API was down) — skip
    const t = new Date(s.t);
    if (t.getTime() < windowStart) {
      // outside window: track for last_seen / session continuity, don't accumulate
      for (const name of s.online_players) lastSeenAt.set(name, t);
      prevOnline = new Set(s.online_players);
      continue;
    }

    const nowOnline = new Set(s.online_players);

    // For each player in this sample: if continuing a session from last sample,
    // accumulate the minutes since their last appearance. If they're back after
    // a long gap, that's a new session — and the prior session was already
    // counted when they dropped out of prevOnline.
    for (const name of nowOnline) {
      lastSeenAt.set(name, t);
      const prev = lastInSession.get(name);
      if (prev) {
        const gapMin = (t - prev) / 60_000;
        if (gapMin <= SESSION_GAP_MIN) {
          // continuation of same session
          const tot = ensureTotal(name);
          tot.minutes += gapMin;
          // attribute hour-of-day / day-of-week to the start of the gap
          byHour[prev.getUTCHours()] += gapMin;
          byDow[prev.getUTCDay()]    += gapMin;

          if (t.getTime() >= weekStart) ensureWeek(name).minutes += gapMin;

          // update longest session for this run
          const ss = sessionStart.get(name) ?? prev;
          const sessLenMin = (t - ss) / 60_000;
          if (sessLenMin > tot.longest_session_min) tot.longest_session_min = sessLenMin;
        } else {
          // gap too large — they reappear after a hidden disconnect
          // (the prior session was already counted when they fell out of prevOnline,
          //  except for the rare case of a single-sample session that was immediately
          //  followed by an API outage. Acceptable corner case for v1.)
          sessionStart.set(name, t);
        }
      } else {
        // first-ever sighting — start their first session
        sessionStart.set(name, t);
      }
      lastInSession.set(name, t);
    }

    // Players who were online last sample but not this one: session ended.
    for (const name of prevOnline) {
      if (!nowOnline.has(name)) {
        ensureTotal(name).sessions += 1;
        const last = lastInSession.get(name);
        if (last && last.getTime() >= weekStart) ensureWeek(name).sessions += 1;
        sessionStart.delete(name);
      }
    }

    prevOnline = nowOnline;
  }

  // Close out any sessions still "open" at end-of-data.
  for (const name of prevOnline) {
    ensureTotal(name).sessions += 1;
    const last = lastInSession.get(name);
    if (last && last.getTime() >= weekStart) ensureWeek(name).sessions += 1;
  }

  // Round minutes to whole numbers for clean JSON.
  for (const k of Object.keys(totals)) {
    totals[k].minutes = Math.round(totals[k].minutes);
    totals[k].longest_session_min = Math.round(totals[k].longest_session_min);
  }
  for (const k of Object.keys(thisWeek)) {
    thisWeek[k].minutes = Math.round(thisWeek[k].minutes);
  }

  const leaderboard = Object.entries(totals)
    .map(([name, v]) => ({ name, minutes: v.minutes }))
    .sort((a, b) => b.minutes - a.minutes);

  const lastSeen = {};
  for (const [name, d] of lastSeenAt) lastSeen[name] = d.toISOString();

  // The "now_online" comes from the most recent non-null sample.
  let nowOnline = [];
  for (let i = samples.length - 1; i >= 0; i--) {
    if (samples[i].online_players) {
      nowOnline = samples[i].online_players;
      break;
    }
  }

  return {
    updated_at: new Date().toISOString(),
    now_online: nowOnline,
    last_seen: lastSeen,
    totals,
    this_week: thisWeek,
    activity_by_hour: byHour.map((v) => Math.round(v)),
    activity_by_dow:  byDow.map((v) => Math.round(v)),
    leaderboard,
  };
}

// ─── Main ───────────────────────────────────────────────────────────────────
const result = await fetchStatus();
const sample = {
  t: new Date().toISOString(),
  online_players: result.ok && result.data.online
    ? (result.data.players?.list?.map((p) => p.name).filter(Boolean) ?? [])
    : (result.ok ? [] : null),
  // null online_players = API failed; site/summary should treat as "unknown", not "offline"
  player_count: result.ok && result.data.online ? (result.data.players?.online ?? 0) : null,
  online: result.ok ? !!result.data.online : null,
  reason: result.ok ? undefined : result.reason,
};
appendSample(sample);

const summary = buildSummary();
fs.writeFileSync(SUMMARY_PATH, JSON.stringify(summary, null, 2) + "\n");

console.log(`Sample: online=${sample.online} players=${(sample.online_players ?? []).join(",")}`);
console.log(`Summary: ${summary.leaderboard.length} players tracked, ${summary.now_online.length} online now`);
