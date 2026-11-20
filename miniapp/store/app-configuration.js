import { computed, ref } from 'vue'
import { name as defaultAppName } from '@/manifest.json'
import { demoPageLinks } from '@/mock/page-links.js'

export const appConfiguration = ref(null)
export const usingServerPageLinks = ref(false)
export const appName = computed(() => {
  const nickname = appConfiguration.value?.nickname
  return (typeof nickname === 'string' && nickname.trim()) || defaultAppName
})

const emptyPageLinks = { home_banner: [], profile_menu: [] }
export const pageLinks = computed(() => {
  if (!usingServerPageLinks.value) return demoPageLinks
  return appConfiguration.value?.links ?? emptyPageLinks
})
