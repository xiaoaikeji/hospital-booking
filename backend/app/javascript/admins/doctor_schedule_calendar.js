const calendarElement = document.getElementById("doctor-schedule-calendar");
const days = JSON.parse(calendarElement.dataset.days);
const adjustmentUrl = new URL(calendarElement.dataset.adjustmentUrl, window.location.href);
const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

function label(text, classes) {
  const span = document.createElement("span");
  span.className = classes;
  span.textContent = text;
  return span;
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

    const entries = [label(date.getUTCDate(), "d-block text-end fw-medium schedule-calendar-date")];
    if (day.adjusted) entries.push(label("已调整", "d-block text-primary fw-medium"));
    if (day.off) {
      entries.push(label("休诊", "d-block text-danger fw-medium"));
    } else if (day.shifts.length === 0) {
      entries.push(label("无排班", "d-block text-secondary"));
    }

    for (const [shift, capacity] of day.shifts) {
      const row = label("", "d-block text-body mt-1");
      row.append(
        label(shift, "fw-medium"),
        label(" · ", "d-none d-md-inline"),
        label(capacity === null ? "默认限额" : `${capacity} 号`, "d-block d-md-inline")
      );
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
    const details = Array.from(link.children).slice(1).map((entry) => entry.textContent);
    link.setAttribute("aria-label", [date, ...details].join("，"));
    if (isToday) link.setAttribute("aria-current", "date");
  }
});
calendar.render();
