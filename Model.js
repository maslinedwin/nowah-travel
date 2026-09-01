.pragma library

// Model.js — pure trip-state engine for the Nowah Omarchy plugin.
//
// Ported from apps/mobile/utils/widgetTripState.ts, simplified for the slim
// trip projection device tokens receive from GET /trips:
//   trip:   { id, name, status, tripStatus, startDate, endDate, dateRange,
//             destination, destinationCity, destinationCountry, weather,
//             coverPhotoUrl, flights: [...] }
//   flight: { flightNumber, depCode, arrCode, depAt, arrAt }
//
// PURITY CONTRACT (same as the mobile source): no Qt imports, no Date.now(),
// no I/O — everything is a function of its inputs so the whole state machine
// runs under `node --test` (see tests/model.test.mjs, which evaluates this
// file in a bare vm context). Top-level declarations use `var`/`function`
// only, so they attach to the library scope in both QML and node:vm.

// ============================================
// TUNING CONSTANTS
// ============================================

var PREP_WINDOW_MS = 48 * 3600000;              // data-forward card from T-48h
var ACTIVE_BEFORE_DEP_MS = 3 * 3600000;         // flight goes live at T-3h
var LANDED_GRACE_MS = 30 * 60000;               // keep "landed" visible briefly
var POST_TRIP_WINDOW_MS = 48 * 3600000;         // post-trip state lingers 48h
var FLIGHT_FALLBACK_DURATION_MS = 6 * 3600000;  // end bound when arrival is unparseable

// ============================================
// BRAND + STATUS COLORS
// ============================================

var WIDGET_STATUS_COLORS = {
  green: "#00A86B", // on time / scheduled / in the air
  amber: "#FBBF24", // minor delay / attention
  red: "#EF4444",   // major delay (30m+) / cancelled
  blue: "#3B82F6"   // landed / arrived
};

var BRAND = {
  jade: "#00A86B",
  jadeText: "#1FD08A",
  jadeHover: "#00965F"
};

function getFlightStatusColor(status, delayMinutes) {
  var s = String(status || "").toUpperCase();
  if (s === "CANCELLED") return WIDGET_STATUS_COLORS.red;
  var delay = (delayMinutes === undefined || delayMinutes === null) ? 0 : Number(delayMinutes);
  if (isNaN(delay)) delay = 0;
  if (s === "DELAYED" || delay > 0)
    return delay >= 30 ? WIDGET_STATUS_COLORS.red : WIDGET_STATUS_COLORS.amber;
  if (s === "LANDED" || s === "ARRIVED") return WIDGET_STATUS_COLORS.blue;
  return WIDGET_STATUS_COLORS.green;
}

// ============================================
// DATE HELPERS
// ============================================

/**
 * Parse the ISO shapes that appear on bookings. Date-only strings are LOCAL
 * midnight (matching date-fns parseISO, used by the app's Trips tab) — plain
 * `new Date('2026-07-14')` would be UTC midnight and shift a day in western
 * timezones. Datetime strings without an offset are already local per spec.
 */
function parseBookingDate(iso) {
  if (!iso) return null;
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (m) {
    var d0 = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    return isNaN(d0.getTime()) ? null : d0;
  }
  var d = new Date(iso);
  return isNaN(d.getTime()) ? null : d;
}

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

/** Calendar-day distance (local): 23:59 tonight -> departure at 00:30 is 1 day, not 0. */
function calendarDaysUntil(target, now) {
  return Math.round((startOfDay(target).getTime() - startOfDay(now).getTime()) / 86400000);
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n;
}

/** Local 'YYYY-MM-DD' (used for the public flight-status --date argument). */
function localISODate(d) {
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
}

function formatClock(d) {
  if (!d) return "--:--";
  return d.getHours() + ":" + pad2(d.getMinutes());
}

// ============================================
// SEGMENTS
// ============================================

/**
 * Flatten the slim flights ({flightNumber, depCode, arrCode, depAt, arrAt})
 * of every trip into chronologically sorted segments. Unparseable departures
 * are dropped; missing/inverted arrivals fall back to dep + 6h.
 */
function flightSegments(trips) {
  var segs = [];
  var list = trips || [];
  for (var i = 0; i < list.length; i++) {
    var trip = list[i];
    var flights = trip.flights || [];
    for (var j = 0; j < flights.length; j++) {
      var f = flights[j];
      var dep = parseBookingDate(f.depAt);
      if (!dep) continue;
      var arr = parseBookingDate(f.arrAt);
      if (!arr || arr.getTime() <= dep.getTime())
        arr = new Date(dep.getTime() + FLIGHT_FALLBACK_DURATION_MS);
      segs.push({ trip: trip, flight: f, dep: dep, arr: arr });
    }
  }
  segs.sort(function (a, b) { return a.dep.getTime() - b.dep.getTime(); });
  return segs;
}

/**
 * When the trip is truly over. Round trips (>=2 flights) end when the last
 * flight lands — trip.endDate is often the return DATE at local midnight, so
 * date math alone would strand the widget "in destination" after flying home.
 * One-way/no-flight trips fall back to the trip endDate.
 */
function tripEffectiveEnd(trip, segs) {
  var mine = (segs || []).filter(function (s) { return s.trip.id === trip.id; });
  if (mine.length >= 2) return mine[mine.length - 1].arr;
  return parseBookingDate(trip.endDate);
}

function tripStartAnchor(trip, segs) {
  var st = parseBookingDate(trip.startDate);
  if (st) return st;
  var list = segs || [];
  for (var i = 0; i < list.length; i++)
    if (list[i].trip.id === trip.id) return list[i].dep;
  return null;
}

// ============================================
// THE STATE MACHINE
// ============================================

/**
 * Single decision point for the bar widget / panel state. Priority order
 * (same ladder as mobile): active flight -> prep -> in destination ->
 * countdown -> post-trip -> idle.
 *
 * Returns { state, trip, seg, daysUntil }:
 *   state:     "active_flight" | "prep" | "in_destination" | "countdown"
 *              | "post_trip" | "idle"
 *   trip:      the driving trip (null when idle)
 *   seg:       the driving flight segment ({trip, flight, dep, arr}) or null
 *   daysUntil: calendar days to the anchor for prep/countdown, 0 for the
 *              "now" states, -1 when idle
 */
function deriveTripMonitor(trips, now) {
  var list = trips || [];
  var nowMs = now.getTime();
  var segs = flightSegments(list);
  var i, s, t;

  // 1. Active flight — any segment (outbound, return, or middle leg) whose
  // live window [dep - 3h, arr + 30m] covers now.
  for (i = 0; i < segs.length; i++) {
    s = segs[i];
    if (nowMs >= s.dep.getTime() - ACTIVE_BEFORE_DEP_MS &&
        nowMs <= s.arr.getTime() + LANDED_GRACE_MS)
      return { state: "active_flight", trip: s.trip, seg: s, daysUntil: 0 };
  }

  // 2. Prep — inside T-48h of an upcoming departure.
  for (i = 0; i < segs.length; i++) {
    s = segs[i];
    if (nowMs >= s.dep.getTime() - PREP_WINDOW_MS &&
        nowMs < s.dep.getTime() - ACTIVE_BEFORE_DEP_MS)
      return { state: "prep", trip: s.trip, seg: s, daysUntil: calendarDaysUntil(s.dep, now) };
  }

  // 3. In destination — today inside a trip window after the first arrival,
  // or a no-flight trip qualifying by dates alone. A round trip whose LAST
  // flight has landed is over — post-trip owns it, not "in destination".
  for (i = 0; i < list.length; i++) {
    t = list[i];
    var start = parseBookingDate(t.startDate);
    var end = parseBookingDate(t.endDate);
    if (!start || !end) continue;
    if (nowMs < start.getTime() || nowMs > end.getTime()) continue;
    var mine = segs.filter(function (x) { return x.trip.id === t.id; }); // eslint-disable-line no-loop-func
    if (mine.length === 0)
      return { state: "in_destination", trip: t, seg: null, daysUntil: 0 };
    var effEnd = tripEffectiveEnd(t, segs);
    if (effEnd && effEnd.getTime() + LANDED_GRACE_MS < nowMs) continue; // flew home
    var landed = mine.some(function (x) { return x.arr.getTime() + LANDED_GRACE_MS < nowMs; });
    if (landed)
      return { state: "in_destination", trip: t, seg: null, daysUntil: 0 };
  }

  // 4. Countdown — earliest upcoming anchor (flight departure or, for
  // no-flight trips, the trip start date).
  var anchor = null;
  for (i = 0; i < segs.length; i++) {
    if (segs[i].dep.getTime() > nowMs) {
      anchor = { at: segs[i].dep, trip: segs[i].trip, seg: segs[i] };
      break;
    }
  }
  for (i = 0; i < list.length; i++) {
    t = list[i];
    if ((t.flights || []).length > 0) continue;
    var st = parseBookingDate(t.startDate);
    if (st && st.getTime() > nowMs && (!anchor || st.getTime() < anchor.at.getTime()))
      anchor = { at: st, trip: t, seg: null };
  }
  if (anchor)
    return { state: "countdown", trip: anchor.trip, seg: anchor.seg, daysUntil: calendarDaysUntil(anchor.at, now) };

  // 5. Post-trip — a trip's effective end fell within the last 48h.
  var ended = null;
  for (i = 0; i < list.length; i++) {
    t = list[i];
    var e = tripEffectiveEnd(t, segs);
    if (!e) continue;
    if (e.getTime() < nowMs && nowMs - e.getTime() <= POST_TRIP_WINDOW_MS &&
        (!ended || e.getTime() > ended.end.getTime()))
      ended = { trip: t, end: e };
  }
  if (ended)
    return { state: "post_trip", trip: ended.trip, seg: null, daysUntil: 0 };

  // 6. Idle.
  return { state: "idle", trip: null, seg: null, daysUntil: -1 };
}

// ============================================
// FLIGHT CARD
// ============================================

function compactFlightNumber(s) {
  return String(s || "").replace(/\s+/g, "").toUpperCase();
}

/**
 * Build the flight-day hero payload from a segment, enriched by the public
 * flight-status feed ONLY when it refers to THIS flight (compact flight
 * numbers must match — same rule as the mobile Live Activity merge).
 *
 * `publicStatus` accepts either the status.json flightStatus envelope
 * ({flightNumber, fetchedAt, data}) or a bare data payload; both camelCase
 * variants (status/flightStatus, progressPercent/progress) are tolerated.
 */
function buildFlightCard(seg, publicStatus, now) {
  var flight = (seg && seg.flight) || {};
  var payload = null;
  if (publicStatus) {
    var data = (publicStatus.data !== undefined && publicStatus.data !== null)
      ? publicStatus.data
      : publicStatus;
    var num = publicStatus.flightNumber !== undefined
      ? publicStatus.flightNumber
      : (data && data.flightNumber);
    if (compactFlightNumber(num) !== "" &&
        compactFlightNumber(num) === compactFlightNumber(flight.flightNumber))
      payload = data;
  }

  var status = payload ? String(payload.status || payload.flightStatus || "") : "";
  var delay = 0;
  if (payload && payload.delayMinutes !== undefined && payload.delayMinutes !== null) {
    delay = Number(payload.delayMinutes);
    if (isNaN(delay)) delay = 0;
  }

  var progress = NaN;
  if (payload) {
    if (payload.progressPercent !== undefined && payload.progressPercent !== null)
      progress = Number(payload.progressPercent);
    else if (payload.progress !== undefined && payload.progress !== null)
      progress = Number(payload.progress);
  }
  if (isNaN(progress)) {
    // Time-based estimate once airborne; 0 before departure.
    if (now.getTime() >= seg.dep.getTime() && seg.arr.getTime() > seg.dep.getTime())
      progress = ((now.getTime() - seg.dep.getTime()) / (seg.arr.getTime() - seg.dep.getTime())) * 100;
    else
      progress = 0;
  }
  progress = Math.min(100, Math.max(0, progress));

  var label = "Scheduled";
  if (status) {
    var up = status.toUpperCase();
    if (up === "DELAYED" && delay > 0) label = "Delayed " + Math.round(delay) + "m";
    else label = up.charAt(0) + up.slice(1).toLowerCase().replace(/_/g, " ");
  } else if (delay > 0) {
    label = "Delayed " + Math.round(delay) + "m";
  }

  return {
    flightNumber: flight.flightNumber || "",
    depCode: flight.depCode || "",
    arrCode: flight.arrCode || "",
    depClock: formatClock(seg.dep),
    arrClock: formatClock(seg.arr),
    statusColor: getFlightStatusColor(status, delay),
    minutesToDep: Math.round((seg.dep.getTime() - now.getTime()) / 60000),
    progressPercent: Math.round(progress),
    statusLabel: label
  };
}

// ============================================
// PANEL HELPERS
// ============================================

/** Trips that have not ended yet (effective end + grace), sorted by start. */
function upcomingTrips(trips, now) {
  var list = trips || [];
  var segs = flightSegments(list);
  var nowMs = now.getTime();
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var t = list[i];
    var end = tripEffectiveEnd(t, segs);
    var start = tripStartAnchor(t, segs);
    if (end) {
      if (end.getTime() + LANDED_GRACE_MS < nowMs) continue; // over
    } else if (!start || start.getTime() <= nowMs) {
      continue; // no usable window and not in the future
    }
    out.push(t);
  }
  out.sort(function (a, b) {
    var sa = tripStartAnchor(a, segs);
    var sb = tripStartAnchor(b, segs);
    return (sa ? sa.getTime() : Infinity) - (sb ? sb.getTime() : Infinity);
  });
  return out;
}

function countdownLabel(days) {
  if (days < 0) return "";
  if (days === 0) return "Today";
  if (days === 1) return "Tomorrow";
  return "in " + days + "d";
}

/** Bar-icon form: "today" / "1d" / "12d". */
function countdownShort(days) {
  if (days < 0) return "";
  if (days === 0) return "today";
  return days + "d";
}

var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Mar 12 – 24" / "Mar 28 – Apr 4" / "Dec 30, 2026 – Jan 5, 2027". */
function formatDateRange(startDate, endDate) {
  var s = parseBookingDate(startDate);
  var e = parseBookingDate(endDate);
  if (!s && !e) return "";
  if (s && !e) return MONTH_NAMES[s.getMonth()] + " " + s.getDate();
  if (!s) return MONTH_NAMES[e.getMonth()] + " " + e.getDate();
  if (s.getFullYear() !== e.getFullYear())
    return MONTH_NAMES[s.getMonth()] + " " + s.getDate() + ", " + s.getFullYear() +
      " – " + MONTH_NAMES[e.getMonth()] + " " + e.getDate() + ", " + e.getFullYear();
  if (s.getMonth() === e.getMonth())
    return MONTH_NAMES[s.getMonth()] + " " + s.getDate() + " – " + e.getDate();
  return MONTH_NAMES[s.getMonth()] + " " + s.getDate() +
    " – " + MONTH_NAMES[e.getMonth()] + " " + e.getDate();
}

/** Prefer the server-provided trip.dateRange, else format the dates locally. */
function tripDateRange(trip) {
  if (!trip) return "";
  if (trip.dateRange) return trip.dateRange;
  return formatDateRange(trip.startDate, trip.endDate);
}

/** Small Nerd Font weather map (nf-weather-* range). */
function weatherGlyph(condition) {
  var c = String(condition || "").toLowerCase();
  if (c.indexOf("thunder") >= 0 || c.indexOf("storm") >= 0) return "\ue31d";
  if (c.indexOf("snow") >= 0 || c.indexOf("sleet") >= 0 || c.indexOf("ice") >= 0) return "\ue31a";
  if (c.indexOf("rain") >= 0 || c.indexOf("shower") >= 0 || c.indexOf("drizzle") >= 0) return "\ue318";
  if (c.indexOf("cloud") >= 0 || c.indexOf("overcast") >= 0 || c.indexOf("fog") >= 0 || c.indexOf("mist") >= 0) return "\ue33d";
  if (c.indexOf("clear") >= 0 || c.indexOf("sun") >= 0) return "\ue30d";
  return "\ue302";
}
