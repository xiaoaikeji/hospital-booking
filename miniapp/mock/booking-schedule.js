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
