import { computed, ref } from 'vue'
import { getBookingSchedule, getScheduledDoctors } from '@/mock/booking-schedule.js'
import { bookingSchedule, configurationStatus } from '@/store/app-configuration.js'
import { bookingDoctors, directoryDemoMode } from '@/store/booking-directory.js'

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
const SHIFT_LABELS = { AM: '上午', PM: '下午', FULL: '全天', NIGHT: '晚班' }

const publishedSchedule = computed(() => {
  if (configurationStatus.value === 'error') return []
  return bookingSchedule.value.map(({ date, doctors }) => ({
    date,
    label: date.slice(5).replace('-', '–'),
    weekday: WEEKDAYS[new Date(date + 'T00:00:00Z').getUTCDay()],
    doctors,
  }))
})

export const scheduleMessage = computed(() => {
  if (configurationStatus.value === 'loading') return '正在读取排班'
  return publishedSchedule.value.length ? '当日暂无排班' : '排班暂不可用'
})

export function shiftLabels(day, doctorId) {
  return (day?.doctors?.[doctorId] ?? []).map(slot => SHIFT_LABELS[slot]).filter(Boolean)
}

export function useBookingCalendar(isDemo = () => directoryDemoMode) {
  const demoSchedule = ref([])
  const selectedDate = ref('')
  const schedule = computed(() => isDemo() ? demoSchedule.value : publishedSchedule.value)
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
  const scheduledDoctors = computed(() => {
    const day = selectedDay.value
    if (!day) return []
    if (isDemo()) return getScheduledDoctors(day)
    return bookingDoctors.value.filter(doctor => shiftLabels(day, doctor.id).length)
  })

  function loadDay(day) { selectedDate.value = day.date }
  function refresh() { if (isDemo()) demoSchedule.value = getBookingSchedule() }

  return { schedule, selectedDate, selectedDay, scheduledDoctors, loadDay, refresh }
}
