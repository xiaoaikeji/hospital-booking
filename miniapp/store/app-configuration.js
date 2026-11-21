import { computed, ref } from 'vue'
import { name as defaultAppName } from '@/manifest.json'
import { demoPageLinks } from '@/mock/page-links.js'
import { loadAppConfiguration } from '@/request/http.js'

const appConfiguration = ref(null)
export const configurationStatus = ref('loading')
let pending
let revision = 0

export function markAppDisabled() {
  revision++
  appConfiguration.value = null
  configurationStatus.value = 'disabled'
}

export function refreshAppConfiguration() {
  if (pending) return pending
  if (configurationStatus.value !== 'disabled') configurationStatus.value = 'loading'

  const started = revision
  pending = loadAppConfiguration().then(({ status, config }) => {
    if (started !== revision) return
    if (status === 'ready') appConfiguration.value = config
    if (status === 'disabled') appConfiguration.value = null
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
