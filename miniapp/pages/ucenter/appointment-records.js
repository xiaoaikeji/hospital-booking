import { computed, ref } from 'vue'
import { onHide, onShow, onUnload } from '@dcloudio/uni-app'
import { listAppointments, nextChangeAt } from '@/mock/appointments.js'
import { session } from '@/mock/session.js'

export function useAppointmentRecords() {
  const records = ref([])
  const now = ref(Date.now())
  const error = ref('')
  let timer

  function updateClock() {
    clearTimeout(timer)
    now.value = Date.now()
    const next = records.value.reduce((earliest, record) => Math.min(earliest, nextChangeAt(record, now.value)), Infinity)
    if (Number.isFinite(next)) timer = setTimeout(updateClock, next - now.value)
  }
  function refresh() {
    try {
      records.value = listAppointments(session.value?.phone)
      error.value = ''
    } catch {
      records.value = []
      error.value = '读取预约记录失败，点此重试'
    }
    updateClock()
  }
  function stop() {
    clearTimeout(timer)
  }
  onShow(refresh)
  onHide(stop)
  onUnload(stop)
  const visibleRecords = computed(() => records.value.filter(item => item.owner === session.value?.phone))
  return { records: visibleRecords, now, error, refresh }
}
