import { computed, ref, watch } from 'vue'
import { onHide, onReachBottom, onShow, onUnload } from '@dcloudio/uni-app'
import { loadDoctors } from '@/request/booking-directory.js'
import { toBookingDoctor } from '@/store/booking-directory.js'
import { pauseApp } from '@/utils/app-access.js'

export function useDoctorList(filters, debounce = 0) {
  const rows = ref([])
  const doctors = computed(() => rows.value.map(toBookingDoctor))
  const status = ref('loading')
  let nextPage
  let revision = 0
  let timer
  let visible = false

  async function fetchPage(query, page, started) {
    status.value = 'loading'
    try {
      const result = await loadDoctors({ ...query, page })
      if (started !== revision) return
      rows.value = page === 1 ? result.doctors : [...rows.value, ...result.doctors]
      nextPage = result.next_page
      status.value = 'ready'
    } catch (error) {
      if (started !== revision) return
      status.value = 'error'
      if (error.appDisabled) pauseApp()
    }
  }

  function cancelPending() {
    clearTimeout(timer)
    revision++
  }

  function refresh(delay = 0) {
    cancelPending()
    nextPage = null
    const query = filters.value
    if (!query) return

    status.value = 'loading'
    const started = revision
    if (delay) timer = setTimeout(() => fetchPage(query, 1, started), delay)
    else return fetchPage(query, 1, started)
  }

  watch(filters, () => {
    rows.value = []
    if (visible) refresh(debounce)
  }, { flush: 'sync' })
  onShow(() => {
    visible = true
    refresh()
  })
  onHide(() => {
    visible = false
    cancelPending()
  })
  onUnload(cancelPending)
  onReachBottom(() => {
    if (filters.value && nextPage && status.value === 'ready') fetchPage(filters.value, nextPage, revision)
  })

  return { doctors, status, refresh }
}
