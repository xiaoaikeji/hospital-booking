import { computed, ref } from 'vue'
import { name as defaultAppName } from '@/manifest.json'

export const appConfiguration = ref(null)
export const appName = computed(() => {
  const nickname = appConfiguration.value?.nickname
  return (typeof nickname === 'string' && nickname.trim()) || defaultAppName
})
