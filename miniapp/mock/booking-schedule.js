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
      doctorIds: date.getDay() % 2 === 0 ? [1, 2] : [2, 1],
    }
  })
}

export async function fetchScheduledDoctors(date) {
  const day = getBookingSchedule().find(item => item.date === date)
  // 模拟排班接口的响应时间，方便在开发者工具里观察日期切换。
  await new Promise(resolve => setTimeout(resolve, 400))
  return (day?.doctorIds ?? []).map(id => doctors.find(doctor => doctor.id === id)).filter(Boolean)
}
