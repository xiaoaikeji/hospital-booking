import { computed, ref } from 'vue'
import { getBookingSchedule, getScheduledDoctors } from '@/mock/booking-schedule.js'

export function useBookingCalendar() {
  const schedule = ref([])
  const selectedDay = ref(null)
  const scheduledDoctors = computed(() => selectedDay.value ? getScheduledDoctors(selectedDay.value) : [])

  function loadDay(day) {
    selectedDay.value = day
  }

  function refresh() {
    schedule.value = getBookingSchedule()
    loadDay(schedule.value.find(day => day.date === selectedDay.value?.date) ?? schedule.value[0])
  }

  return { schedule, selectedDay, scheduledDoctors, loadDay, refresh }
}
