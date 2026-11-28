const calendarElement = document.getElementById("doctor-schedule-calendar");
const days = JSON.parse(calendarElement.dataset.days);
const adjustmentUrl = new URL(calendarElement.dataset.adjustmentUrl, window.location.href);
const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

let serverTime = Number(calendarElement.dataset.serverTime);
let sampledAt = performance.now();

function hospitalNow() {
  return serverTime + performance.now() - sampledAt;
}

function label(text, classes) {
  const span = document.createElement("span");
  span.className = classes;
  span.textContent = text;
  return span;
}

function statusLabel(text, colorClass) {
  const row = label("", "d-block mt-1");
  const badge = label("", `badge badge-sm lh-sm border-0 px-md-2 py-md-1 ${colorClass}`);
  badge.append(label(text, "fs-6 d-md-none"), label(text, "fs-5 d-none d-md-inline"));
  row.append(badge);
  row.dataset.label = text;
  return row;
}

function updateShiftStatus(status, shift, now) {
  const closed = now >= shift.cutoff_at;
  const available = shift.slots?.find((slot) => now < slot.cutoff_at)?.shift_available ?? shift.remaining;
  if (closed) status.textContent = "已截止";
  else status.textContent = available === 0 ? "已满" : `可约 ${available} 号`;
  status.classList.toggle("text-secondary", closed);
  status.classList.toggle("text-danger", !closed && available === 0);
}

function updateDayLabel(link, date) {
  const details = Array.from(link.children).slice(1).map((entry) => entry.dataset.label || entry.textContent);
  link.setAttribute("aria-label", [date, ...details].join("，"));
}

const calendar = new FullCalendar.Calendar(calendarElement, {
  initialView: "dayGridMonth",
  initialDate: calendarElement.dataset.initialDate,
  now: calendarElement.dataset.today,
  timeZone: "UTC",
  firstDay: 1,
  headerToolbar: false,
  showNonCurrentDates: false,
  fixedWeekCount: false,
  height: "auto",
  dayHeaderContent: ({ date }) => weekdays[date.getUTCDay()],
  dayCellContent({ date }) {
    const day = days[date.toISOString().slice(0, 10)];
    if (!day) return { domNodes: [] };

    const entries = [label(date.getUTCDate(), "d-block text-end fw-medium")];
    if (day.adjusted) entries.push(statusLabel("已调整", "bg-primary-lt"));
    if (day.off) {
      entries.push(statusLabel("休诊", "bg-danger-lt"));
    } else if (day.shifts.length === 0) {
      entries.push(label("无排班", "d-block text-secondary"));
    }

    for (const shift of day.shifts) {
      const row = label("", "d-block text-body mt-1");
      row.append(label(shift.label, "fw-medium"));
      if (shift.total !== null) {
        const status = label("", "d-block d-md-inline");
        status.dataset.shiftStatus = shift.time_slot;
        updateShiftStatus(status, shift, hospitalNow());
        row.append(
          label(" · ", "d-none d-md-inline"), status,
          label(` 共 ${shift.total} 号`, "d-none d-md-block small text-secondary")
        );
      }
      entries.push(row);
    }
    return { domNodes: entries };
  },
  dayCellDidMount({ el, isToday }) {
    const date = el.dataset.date;
    if (!days[date]) return;

    const link = el.querySelector(".fc-daygrid-day-number");
    adjustmentUrl.searchParams.set("date", date);
    link.href = adjustmentUrl.href;
    link.classList.add("stretched-link");
    updateDayLabel(link, date);
    if (isToday) link.setAttribute("aria-current", "date");

    el.addEventListener("pointerenter", (event) => {
      if (event.pointerType !== "touch") el.classList.add("bg-surface-secondary");
    });
    el.addEventListener("pointerleave", () => el.classList.remove("bg-surface-secondary"));
  }
});
calendar.render();

let timer;
function refreshShiftStatuses() {
  clearTimeout(timer);
  const now = hospitalNow();
  for (const cell of calendarElement.querySelectorAll(".fc-daygrid-day[data-date]")) {
    const date = cell.dataset.date;
    const link = cell.querySelector(".fc-daygrid-day-number");
    if (!days[date]?.shifts.length || !link) continue;
    for (const status of link.querySelectorAll("[data-shift-status]")) {
      const shift = days[date].shifts.find((item) => item.time_slot === status.dataset.shiftStatus);
      updateShiftStatus(status, shift, now);
    }
    updateDayLabel(link, date);
  }
  timer = setTimeout(refreshShiftStatuses, 60_000 - (now % 60_000));
}

let clockRequest = 0;
async function syncClock() {
  const request = ++clockRequest;
  const serverTimeAtRequest = hospitalNow();
  refreshShiftStatuses();
  try {
    const response = await fetch(calendarElement.dataset.clockUrl, { headers: { Accept: "application/json" }, cache: "no-store" });
    if (!response.ok) return;
    const receivedAt = performance.now();
    const { server_time: latest } = await response.json();
    if (request !== clockRequest || !Number.isFinite(latest)) return;
    serverTime = latest >= serverTimeAtRequest ? Math.max(latest, serverTime + receivedAt - sampledAt) : latest;
    sampledAt = receivedAt;
    refreshShiftStatuses();
  } catch {
    // Continue from the last server sample until the next successful sync.
  }
}

window.addEventListener("pageshow", syncClock);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) syncClock();
});
refreshShiftStatuses();
