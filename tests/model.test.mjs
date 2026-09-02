// Tests for Model.js — run with `node --test tests/` from the plugin root.
//
// Model.js is a QML `.pragma library` file, so it cannot be imported as a
// module: we strip the pragma line and evaluate the body in a bare vm
// context. Top-level `var`/`function` declarations attach to that context's
// global object, which is how QML's library scope behaves too.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, '..', 'Model.js'), 'utf8');
assert.match(source, /^\.pragma library\n/, 'Model.js must start with .pragma library');

const body = source.replace(/^\.pragma\s+library[^\n]*\n/, '');
const M = vm.createContext({});
vm.runInContext(body, M, { filename: 'Model.js' });

// ---------------------------------------------------------------------------
// Fixtures — slim device-token trip shape.
// ---------------------------------------------------------------------------

const trip = (over = {}) => ({
  id: 't-tokyo',
  name: 'Tokyo Trip',
  status: 'confirmed',
  tripStatus: 'upcoming',
  startDate: '2026-03-12',
  endDate: '2026-03-24',
  dateRange: { start: '2026-03-12', end: '2026-03-24' },
  destination: 'Tokyo, Japan',
  destinationCity: 'Tokyo',
  destinationCountry: 'Japan',
  weather: null,
  coverPhotoUrl: null,
  flights: [],
  ...over,
});

const flight = (over = {}) => ({
  flightNumber: 'NH 106',
  depCode: 'LAX',
  arrCode: 'HND',
  depAt: '2026-03-12T10:00:00',
  arrAt: '2026-03-12T22:00:00',
  ...over,
});

const tokyoTrip = () => trip({ flights: [flight()] });

// Round trip that has fully ended (both legs flown).
const endedRoundTrip = () => trip({
  id: 't-ended',
  flights: [
    flight(),
    flight({
      flightNumber: 'NH 105',
      depCode: 'HND',
      arrCode: 'LAX',
      depAt: '2026-03-23T09:00:00',
      arrAt: '2026-03-23T17:00:00',
    }),
  ],
});

// ---------------------------------------------------------------------------
// deriveTripMonitor state ladder
// ---------------------------------------------------------------------------

test('countdown for a trip 10 days out', () => {
  const now = new Date(2026, 2, 2, 12, 0); // Mar 2 noon, dep Mar 12 10:00
  const m = M.deriveTripMonitor([tokyoTrip()], now);
  assert.equal(m.state, 'countdown');
  assert.equal(m.trip.id, 't-tokyo');
  assert.equal(m.daysUntil, 10);
  assert.equal(m.seg.flight.flightNumber, 'NH 106');
});

test('prep at T-24h', () => {
  const now = new Date(2026, 2, 11, 10, 0); // exactly 24h before departure
  const m = M.deriveTripMonitor([tokyoTrip()], now);
  assert.equal(m.state, 'prep');
  assert.equal(m.daysUntil, 1);
  assert.equal(m.seg.flight.depCode, 'LAX');
});

test('active_flight at T-1h', () => {
  const now = new Date(2026, 2, 12, 9, 0); // dep 10:00, window opens 07:00
  const m = M.deriveTripMonitor([tokyoTrip()], now);
  assert.equal(m.state, 'active_flight');
  assert.equal(m.trip.id, 't-tokyo');
  assert.equal(m.daysUntil, 0);
});

test('active_flight mid-flight', () => {
  const now = new Date(2026, 2, 12, 15, 0); // between 10:00 dep and 22:00 arr
  const m = M.deriveTripMonitor([tokyoTrip()], now);
  assert.equal(m.state, 'active_flight');
  assert.equal(m.seg.flight.arrCode, 'HND');
});

test('post_trip after last arrival + 1h with trip ended', () => {
  const now = new Date(2026, 2, 23, 18, 0); // return landed 17:00 (+30m grace passed)
  const m = M.deriveTripMonitor([endedRoundTrip()], now);
  assert.equal(m.state, 'post_trip');
  assert.equal(m.trip.id, 't-ended');
  assert.equal(m.seg, null);
});

test('idle with no trips', () => {
  const m = M.deriveTripMonitor([], new Date(2026, 2, 2, 12, 0));
  assert.equal(m.state, 'idle');
  assert.equal(m.trip, null);
  assert.equal(m.daysUntil, -1);
});

test('in_destination between landed outbound and distant return', () => {
  const roundTrip = trip({
    flights: [
      flight(),
      flight({ flightNumber: 'NH 105', depCode: 'HND', arrCode: 'LAX',
               depAt: '2026-03-23T09:00:00', arrAt: '2026-03-23T17:00:00' }),
    ],
  });
  const now = new Date(2026, 2, 16, 12, 0); // mid-trip, no flight in window
  const m = M.deriveTripMonitor([roundTrip], now);
  assert.equal(m.state, 'in_destination');
  assert.equal(m.trip.id, 't-tokyo');
});

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

test('parseBookingDate handles date-only strings as local midnight', () => {
  const d = M.parseBookingDate('2026-07-14');
  assert.equal(d.getFullYear(), 2026);
  assert.equal(d.getMonth(), 6);
  assert.equal(d.getDate(), 14);
  assert.equal(d.getHours(), 0);
  assert.equal(d.getMinutes(), 0);
});

test('parseBookingDate rejects garbage and empties', () => {
  assert.equal(M.parseBookingDate(''), null);
  assert.equal(M.parseBookingDate(null), null);
  assert.equal(M.parseBookingDate('not-a-date'), null);
});

test('calendarDaysUntil counts calendar days, not 24h blocks', () => {
  const tonight = new Date(2026, 2, 11, 23, 59);
  const earlyTomorrow = new Date(2026, 2, 12, 0, 30);
  assert.equal(M.calendarDaysUntil(earlyTomorrow, tonight), 1);
});

// ---------------------------------------------------------------------------
// Status colors
// ---------------------------------------------------------------------------

test('getFlightStatusColor cases', () => {
  const C = M.WIDGET_STATUS_COLORS;
  assert.equal(M.getFlightStatusColor('CANCELLED'), C.red);
  assert.equal(M.getFlightStatusColor('DELAYED', 40), C.red);
  assert.equal(M.getFlightStatusColor('DELAYED', 10), C.amber);
  assert.equal(M.getFlightStatusColor('LANDED'), C.blue);
  assert.equal(M.getFlightStatusColor(undefined, undefined), C.green);
  assert.equal(M.getFlightStatusColor('EN_ROUTE', 0), C.green);
});

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

test('countdownLabel boundaries', () => {
  assert.equal(M.countdownLabel(0), 'Today');
  assert.equal(M.countdownLabel(1), 'Tomorrow');
  assert.equal(M.countdownLabel(2), 'in 2d');
  assert.equal(M.countdownLabel(14), 'in 14d');
  assert.equal(M.countdownLabel(-1), '');
});

test('countdownShort boundaries', () => {
  assert.equal(M.countdownShort(0), 'today');
  assert.equal(M.countdownShort(1), '1d');
  assert.equal(M.countdownShort(12), '12d');
  assert.equal(M.countdownShort(-1), '');
});

test('formatDateRange and tripDateRange', () => {
  assert.equal(M.formatDateRange('2026-03-12', '2026-03-24'), 'Mar 12 – 24');
  assert.equal(M.formatDateRange('2026-03-28', '2026-04-04'), 'Mar 28 – Apr 4');
  assert.equal(M.tripDateRange(trip()), 'Mar 12 – 24'); // prefers server dateRange
  assert.equal(M.tripDateRange(trip({ dateRange: null })), 'Mar 12 – 24');
});

// ---------------------------------------------------------------------------
// buildFlightCard
// ---------------------------------------------------------------------------

test('buildFlightCard ignores public status on flight-number mismatch', () => {
  const seg = M.flightSegments([tokyoTrip()])[0];
  const now = new Date(2026, 2, 12, 8, 0); // 2h before departure
  const card = M.buildFlightCard(seg, {
    flightNumber: 'JL 15',
    fetchedAt: '2026-03-12T07:55:00Z',
    data: { status: 'DELAYED', delayMinutes: 45, progressPercent: 50 },
  }, now);
  assert.equal(card.statusColor, M.WIDGET_STATUS_COLORS.green);
  assert.equal(card.statusLabel, 'Scheduled');
  assert.equal(card.progressPercent, 0);
  assert.equal(card.minutesToDep, 120);
  assert.equal(card.depCode, 'LAX');
  assert.equal(card.arrCode, 'HND');
});

test('buildFlightCard merges public status on compact flight-number match', () => {
  const seg = M.flightSegments([tokyoTrip()])[0];
  const now = new Date(2026, 2, 12, 8, 0);
  const card = M.buildFlightCard(seg, {
    flightNumber: 'nh106', // compact() normalization: spaces stripped, case-folded
    data: { status: 'DELAYED', delayMinutes: 40 },
  }, now);
  assert.equal(card.statusColor, M.WIDGET_STATUS_COLORS.red);
  assert.equal(card.statusLabel, 'Delayed 40m');
});

test('buildFlightCard in flight: progress from payload, humanized label', () => {
  const seg = M.flightSegments([tokyoTrip()])[0];
  const now = new Date(2026, 2, 12, 15, 0);
  const card = M.buildFlightCard(seg, {
    flightNumber: 'NH 106',
    data: { status: 'EN_ROUTE', progressPercent: 42 },
  }, now);
  assert.equal(card.progressPercent, 42);
  assert.equal(card.statusLabel, 'En route');
  assert.equal(card.statusColor, M.WIDGET_STATUS_COLORS.green);
  assert.ok(card.minutesToDep < 0);
});

test('buildFlightCard with no public status estimates progress from time', () => {
  const seg = M.flightSegments([tokyoTrip()])[0];
  const now = new Date(2026, 2, 12, 16, 0); // 6h into a 12h flight
  const card = M.buildFlightCard(seg, null, now);
  assert.equal(card.progressPercent, 50);
  assert.equal(card.statusLabel, 'Scheduled');
});

// ---------------------------------------------------------------------------
// upcomingTrips
// ---------------------------------------------------------------------------

test('upcomingTrips filters ended trips and sorts by start', () => {
  const past = trip({ id: 't-past', startDate: '2026-01-05', endDate: '2026-01-12', flights: [] });
  const later = trip({ id: 't-later', startDate: '2026-05-01', endDate: '2026-05-09', flights: [] });
  const soon = tokyoTrip();
  const now = new Date(2026, 2, 2, 12, 0);
  const up = M.upcomingTrips([later, past, soon], now);
  // join() instead of deepEqual: arrays from the vm realm have a foreign
  // Array.prototype, which strict deep equality rejects.
  assert.equal(up.map(t => t.id).join(','), 't-tokyo,t-later');
});


// ---------------------------------------------------------------------------
// Local-input bounds (snapshot re-validation, query and recents caps).
// ---------------------------------------------------------------------------

test('sanitizeQuery bounds length, strips control/markup, collapses whitespace', () => {
  const long = 'x'.repeat(500);
  assert.equal(M.sanitizeQuery(long).length, M.MAX_QUERY_CHARS);
  assert.equal(M.sanitizeQuery('  flights to  <b>Tokyo</b>\u200b '), 'flights to bTokyo/b');
  assert.equal(M.sanitizeQuery(42), '');
  assert.equal(M.sanitizeQuery(null), '');
});

test('sanitizeRecents caps count, dedupes, drops junk entries', () => {
  // Arrays cross the vm realm boundary, so compare by value, not prototype.
  const out = M.sanitizeRecents(['a', 'b', 'a', 7, '', 'c', 'd', 'e', 'f']);
  assert.equal(JSON.stringify(out), JSON.stringify(['a', 'b', 'c', 'd']));
  assert.equal(JSON.stringify(M.sanitizeRecents('not an array')), '[]');
  assert.equal(JSON.stringify(M.sanitizeRecents([{ x: 1 }])), '[]');
});

test('sanitizeSnapshot rejects non-objects and normalises a hostile snapshot', () => {
  assert.equal(M.sanitizeSnapshot(null), null);
  assert.equal(M.sanitizeSnapshot([1, 2]), null);
  assert.equal(M.sanitizeSnapshot('str'), null);

  const trips = [];
  for (let i = 0; i < 60; i++) trips.push(trip({ id: 't' + i, name: '<img src=x>' + 'n'.repeat(300) }));
  trips.push(trip({ id: '../evil?x' }));
  const snap = M.sanitizeSnapshot({
    auth: { state: 'pairing', error: 'e'.repeat(500),
            pairing: { userCode: 'ABCD-EFGH', verificationUrl: 'https://evil.example/device?code=ABCD-EFGH', interval: 999, expiresAt: '2099-01-01T00:00:00Z' } },
    trips,
    unreadCount: 50000,
    flightStatus: { flightNumber: 'TK 12', data: { status: 'Delayed<script>', progressPercent: Infinity, delayMinutes: 25 } },
    lastSync: { ok: 'yes', error: 12 },
    extra: 'dropped',
  });
  assert.equal(snap.trips.length, M.SNAPSHOT_MAX_TRIPS);
  assert.equal(snap.trips[0].name.length, 80);
  assert.ok(!snap.trips[0].name.includes('<'));
  assert.ok(!snap.trips.some((t) => t.id.includes('..')));
  assert.equal(snap.auth.state, 'pairing');
  assert.equal(snap.auth.error.length, 120);
  assert.equal(snap.auth.pairing.userCode, 'ABCD-EFGH');
  assert.equal(snap.auth.pairing.verificationUrl, null, 'off-origin verification URL must be dropped');
  assert.equal(snap.auth.pairing.interval, 60);
  assert.equal(snap.unreadCount, 9999, 'in-range values clamp to the display cap');
  assert.equal(M.sanitizeSnapshot({ unreadCount: 1e12 }).unreadCount, 0, 'implausible magnitudes are dropped, not clamped');
  assert.equal(M.sanitizeSnapshot({ unreadCount: -4 }).unreadCount, 0);
  assert.equal(snap.flightStatus.data.status, 'Delayedscript');
  assert.equal(snap.flightStatus.data.progressPercent, null);
  assert.equal(snap.flightStatus.data.delayMinutes, 25);
  assert.equal(snap.lastSync.ok, false);
  assert.equal(snap.lastSync.error, null);
  assert.equal(snap.extra, undefined);
});

test('sanitizeSnapshot caps flights per trip and keeps a valid pairing URL', () => {
  const t = { id: 'ok', flights: new Array(40).fill({ flightNumber: 'TK 12', depCode: 'IST', arrCode: 'JFK', depAt: '2026-09-10T08:05:00', arrAt: '2026-09-10T12:30:00' }) };
  const snap = M.sanitizeSnapshot({ auth: { state: 'pairing', pairing: { userCode: 'ABCD-EFGH', verificationUrl: 'https://app.nowah.xyz/device?code=ABCD-EFGH' } }, trips: [t] });
  assert.equal(snap.trips[0].flights.length, M.SNAPSHOT_MAX_FLIGHTS);
  assert.equal(snap.auth.pairing.verificationUrl, 'https://app.nowah.xyz/device?code=ABCD-EFGH');
  assert.equal(snap.auth.pairing.interval, 5);
  const bad = M.sanitizeSnapshot({ auth: { state: 'root', pairing: { userCode: 'ABCD-EFGH' } } });
  assert.equal(bad.auth.state, 'signed_out');
  assert.equal(bad.auth.pairing, null);
});


test('tripDateRange formats the sanitized {start,end} object and tolerates strings/nulls', () => {
  const formatted = M.tripDateRange(trip());
  assert.equal(typeof formatted, 'string');
  assert.ok(!formatted.includes('[object'), formatted);
  assert.equal(M.tripDateRange(trip({ dateRange: 'Mar 12 - 24' })), 'Mar 12 - 24');
  assert.equal(typeof M.tripDateRange(trip({ dateRange: null })), 'string');
  assert.equal(M.tripDateRange(null), '');
});

test('sanitizeQuery never leaves a lone surrogate at the cut (encodeURIComponent must not throw)', () => {
  const q = M.sanitizeQuery('a'.repeat(199) + '\uD83D\uDE00' + 'tail');
  assert.ok(q.length <= M.MAX_QUERY_CHARS);
  assert.doesNotThrow(() => encodeURIComponent(q));
  assert.equal(M.sanitizeQuery('x\uD83D\uDE00y'), 'x\uD83D\uDE00y', 'intact pairs survive');
});
