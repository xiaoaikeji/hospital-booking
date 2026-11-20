import { doctors } from './doctors.js'

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

export function getBookingSchedule(start = new Date()) {
  return Array.from({ length: 14 }, (_, offset) => {
    const date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + offset)
    const month = String(date.getMonth() + 1).padStart(2, '0')
    const day = String(date.getDate()).padStart(2, '0')
    return {
      date: `${date.getFullYear()}-${month}-${day}`,
      label: `${month}–${day}`,
      weekday: WEEKDAYS[date.getDay()],
      doctorIds: [1, 2],
    }
  })
}

export function getScheduledDoctors(day) {
  return day.doctorIds.map(id => doctors.find(doctor => doctor.id === id)).filter(Boolean)
}

const REMAINING_SEATS = [0, 2, 5, 3, 5, 3, 0, 2, 2, 2, 0, 1, 5, 2, 0]

function clockTime(minutes) {
  return String(Math.floor(minutes / 60)).padStart(2, '0') + ':' + String(minutes % 60).padStart(2, '0')
}

export function getBookingSlots(day, doctorId, now = new Date()) {
  if (!day?.doctorIds.includes(doctorId)) return []
  const [year, month, date] = day.date.split('-').map(Number)
  const offset = (date + doctorId) % 3
  return REMAINING_SEATS.map((_, index) => {
    // 上午 8:00–12:00，下午 14:00–17:30，每个号源半小时。
    const start = (index < 8 ? 8 * 60 : 10 * 60) + index * 30
    const begins = new Date(year, month - 1, date, 0, start)
    const seats = REMAINING_SEATS[(index + offset) % REMAINING_SEATS.length]
    return { label: clockTime(start) + '–' + clockTime(start + 30), remaining: begins <= now ? 0 : seats }
  })
}
