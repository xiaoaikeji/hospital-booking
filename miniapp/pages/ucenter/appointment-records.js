import { ref, watch } from 'vue'
import { onHide, onShow, onUnload } from '@dcloudio/uni-app'
import { bookingStatus, listAppointments, nextChangeAt, statusLabels } from '@/mock/appointments.js'
import { loadAppointments } from '@/request/appointments.js'
import { demoMode, profile, signedIn } from '@/store/session.js'

export function recordStatus(record, now) {
  return demoMode ? bookingStatus(record, now) : record.status
}

export function recordStatusLabel(record, now) {
  return demoMode ? statusLabels[bookingStatus(record, now)] : record.statusLabel
}

export function useAppointmentRecords(orderNo) {
  const records = ref([])
  const now = ref(Date.now())
  const error = ref('')
  const loading = ref(signedIn.value)
  let timer
  let revision = 0

  function updateClock() {
    clearTimeout(timer)
    now.value = Date.now()
    const next = records.value.reduce((earliest, record) => Math.min(earliest, nextChangeAt(record, now.value)), Infinity)
    if (Number.isFinite(next)) timer = setTimeout(updateClock, next - now.value)
  }
  async function refresh() {
    const started = ++revision
    if (!signedIn.value) {
      loading.value = false
      return
    }
    if (!records.value.length) loading.value = true
    try {
      const number = orderNo?.value
      const rows = demoMode
        ? listAppointments(profile.value?.user_no).filter(row => !orderNo || row.no === number)
        : (!orderNo || number ? await loadAppointments(number) : [])
      if (started !== revision) return
      records.value = rows
      error.value = ''
    } catch (failure) {
      if (started !== revision) return
      records.value = []
      error.value = orderNo && failure.statusCode === 404 ? '' : '读取预约记录失败，点此重试'
    } finally {
      if (started === revision) {
        loading.value = false
        if (demoMode) updateClock()
      }
    }
  }
  function stop() {
    revision++
    clearTimeout(timer)
  }
  watch(signedIn, active => {
    if (active) return
    stop()
    records.value = []
    error.value = ''
    loading.value = false
  }, { flush: 'sync' })
  onShow(refresh)
  onHide(stop)
  onUnload(stop)
  return { records, now, error, loading, refresh }
}
