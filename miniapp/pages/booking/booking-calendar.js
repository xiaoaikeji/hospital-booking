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

export function shiftSlots(shift) {
  return shift.slots?.map(slot => ({
    ...slot,
    time_slot: shift.time_slot,
    label: `${slot.start_time}–${slot.end_time}`,
    timed: true,
  })) ?? [shift]
}

export function bookingSlots(day, doctorId) {
  return bookingShifts(day, doctorId).flatMap(shiftSlots)
}

export function bookingSlotKey(slot) {
  if (!slot.time_slot) return slot.label
  return [slot.time_slot, slot.timed ? 'slot' : 'shift', slot.start_time, slot.end_time].join('/')
}

export function shiftClosed(shift, now = Date.now()) {
  return Number.isFinite(shift.cutoff_at) && now >= shift.cutoff_at
}

export function shiftBookable(shift, now = Date.now()) {
  return (shift.remaining == null || shift.remaining > 0) && !shiftClosed(shift, now)
}

export function nextBookableSlot(schedule, doctorId, now) {
  for (const day of schedule) {
    const slot = bookingSlots(day, doctorId).find(item => shiftBookable(item, now))
    if (slot) return { day, slot }
  }
}

export function shiftLabels(day, doctorId, now) {
  return bookingShifts(day, doctorId).map(shift => {
    const slots = shift.slots ?? [shift]
    if (slots.every(slot => shiftClosed(slot, now))) return shift.label + '（已截止）'
    if (!slots.some(slot => shiftBookable(slot, now))) return shift.label + '（已满）'
    return shift.label
  })
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
