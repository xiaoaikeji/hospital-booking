import { computed, ref } from 'vue'
import { onHide, onShow, onUnload } from '@dcloudio/uni-app'
import { getBookingSchedule, getScheduledDoctors } from '@/mock/booking-schedule.js'
import { bookingSchedule, configurationStatus } from '@/store/app-configuration.js'
import { bookingDoctors, directoryDemoMode } from '@/store/booking-directory.js'

const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']
const SHIFT_LABELS = { AM: '上午', PM: '下午', FULL: '全天', NIGHT: '晚班' }

const publishedSchedule = computed(() => {
  if (configurationStatus.value === 'error') return []
  return bookingSchedule.value.map(({ date, doctors, availability }) => ({
    date,
    label: date.slice(5).replace('-', '–'),
    weekday: WEEKDAYS[new Date(date + 'T00:00:00Z').getUTCDay()],
    doctors,
    availability,
  }))
})

export const scheduleMessage = computed(() => {
  if (configurationStatus.value === 'loading') return '正在读取排班'
  return publishedSchedule.value.length ? '当日暂无排班' : '排班暂不可用'
})

export function bookingShifts(day, doctorId) {
  return day?.availability?.[doctorId] ?? (day?.doctors?.[doctorId] ?? []).flatMap(slot => {
    const label = SHIFT_LABELS[slot]
    return label ? [{ time_slot: slot, label }] : []
  })
}

export function shiftClosed(shift, now = Date.now()) {
  return Number.isFinite(shift.cutoff_at) && now >= shift.cutoff_at
}

export function shiftLabels(day, doctorId, now) {
  return bookingShifts(day, doctorId).map(shift => shiftClosed(shift, now) ? shift.label + '（已截止）' : shift.label)
}

export function useBookingCalendar(isDemo = () => directoryDemoMode) {
  const demoSchedule = ref([])
  const selectedDate = ref('')
  const now = ref(Date.now())
  const schedule = computed(() => isDemo() ? demoSchedule.value : publishedSchedule.value)
  const selectedDay = computed(() => schedule.value.find(day => day.date === selectedDate.value) || schedule.value[0])
  const scheduledDoctors = computed(() => {
    const day = selectedDay.value
    if (!day) return []
    if (isDemo()) return getScheduledDoctors(day)
    return bookingDoctors.value.filter(doctor => bookingShifts(day, doctor.id).length)
  })

  let timer
  function refreshClock() { now.value = Date.now() }
  function tick() {
    refreshClock()
    // All published cutoffs fall on a minute boundary.
    timer = setTimeout(tick, 60_000 - (now.value % 60_000))
  }
  const stopClock = () => clearTimeout(timer)
  onShow(() => {
    stopClock()
    if (!isDemo()) tick()
  })
  onHide(stopClock)
  onUnload(stopClock)

  function loadDay(day) { selectedDate.value = day.date }
  function refresh() { if (isDemo()) demoSchedule.value = getBookingSchedule() }

  return { schedule, selectedDate, selectedDay, scheduledDoctors, loadDay, refresh, now, refreshClock }
}
