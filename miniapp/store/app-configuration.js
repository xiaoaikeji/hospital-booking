import { computed, ref } from 'vue'
import { name as defaultAppName } from '@/manifest.json'
import { demoPageLinks } from '@/mock/page-links.js'
import { loadAppConfiguration } from '@/request/http.js'

const appConfiguration = ref(null)
export const configurationStatus = ref('loading')
const disabledListeners = new Set()
let pending
let revision = 0

export function onAppDisabled(listener) {
  disabledListeners.add(listener)
  return () => disabledListeners.delete(listener)
}

function notifyAppDisabled() {
  for (const listener of disabledListeners) listener()
}

export function markAppDisabled() {
  revision++
  appConfiguration.value = null
  configurationStatus.value = 'disabled'
  notifyAppDisabled()
}

export function refreshAppConfiguration() {
  if (pending) return pending
  if (configurationStatus.value !== 'disabled') configurationStatus.value = 'loading'

  const started = revision
  pending = loadAppConfiguration().then(({ status, config }) => {
    if (started !== revision) return
    if (status === 'ready') appConfiguration.value = config
    if (status === 'disabled') {
      appConfiguration.value = null
      configurationStatus.value = 'disabled'
      notifyAppDisabled()
      return
    }
    // 停用已由服务端确认，后续读取失败时仍等待明确恢复。
    if (status !== 'error' || configurationStatus.value !== 'disabled') configurationStatus.value = status
  }).finally(() => { pending = null })
  return pending
}

export const appName = computed(() => {
  const nickname = configurationStatus.value === 'error' ? '' : appConfiguration.value?.nickname
  return (typeof nickname === 'string' && nickname.trim()) || defaultAppName
})

const emptyPageLinks = { home_banner: [], profile_menu: [] }
export const pageLinks = computed(() => {
  if (configurationStatus.value === 'demo') return demoPageLinks
  return appConfiguration.value?.links ?? emptyPageLinks
})

export const hospitalProfile = computed(() => appConfiguration.value?.hospital ?? {})
export const bookingNotice = computed(() => appConfiguration.value?.appointment?.booking_notice ?? '')
export const showUnscheduledDoctors = computed(() => appConfiguration.value?.appointment?.show_unscheduled_doctors ?? true)
export const bookingSymptomsRequired = computed(() => appConfiguration.value?.appointment?.require_booking_remark ?? false)
export const displayFreeFeeWhenFeeIsZero = computed(() => appConfiguration.value?.appointment?.display_free_fee_when_fee_is_zero ?? true)
export const displayHospitalAddress = computed(() => appConfiguration.value?.appointment?.display_hospital_address ?? false)

const emptyDirectory = { departments: [], doctors: [] }
export const bookingDirectory = computed(() => appConfiguration.value?.directory ?? emptyDirectory)
export const bookingSchedule = computed(() => appConfiguration.value?.schedule ?? [])
