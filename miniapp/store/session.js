import { ref } from 'vue'
import { API_ORIGIN, wechatAppId, requestApp } from '../request/http.js'
import { createSessionClient } from '../request/session.js'
import { pauseApp } from '../utils/app-access.js'

const appId = wechatAppId()
export const demoMode = !appId
const storageKey = demoMode ? 'booking-demo-session' : 'booking-session:' + API_ORIGIN + ':' + appId
const saved = uni.getStorageSync(storageKey)
export const signedIn = ref(!!(demoMode ? saved?.user_no || saved?.phone : saved?.token))
const demoUser = mobile => ({ user_no: 'demo', nickname: '体验用户', mobile, booking_phone_required: false })
export const profile = ref(demoMode && signedIn.value ? demoUser(saved.mobile || saved.phone) : null)
let profileVersion = 0
let entryScene

function save(value) {
  if (value) uni.setStorageSync(storageKey, value)
  else uni.removeStorageSync(storageKey)
}

const client = createSessionClient({
  saved: demoMode ? null : saved,
  save,
  loginCode: async () => {
    try { return (await uni.login({ provider: 'weixin' })).code }
    catch { throw new Error('微信登录失败，请重试') }
  },
  send: async (path, options) => {
    const version = profileVersion
    try { return await requestApp(appId, path, options) }
    catch (error) {
      if (error.appDisabled) pauseApp()
      if (error.code === 'account_disabled' && version === profileVersion) profile.value = null
      throw error
    }
  },
  changed: active => {
    signedIn.value = active
    if (!active) {
      profileVersion++
      profile.value = null
    }
  },
})

export async function readProfile() {
  if (demoMode) return profile.value
  const version = profileVersion
  const result = await client.request('me')
  if (!result?.user_no) throw new Error('未取得本人资料，请重试')
  if (version === profileVersion) profile.value = result
  return profile.value
}

export async function signIn() {
  if (demoMode) {
    profile.value ||= demoUser('')
    save(profile.value)
    signedIn.value = true
    return
  }
  const scene = entryScene
  await client.signIn(scene)
  if (entryScene === scene) entryScene = undefined
  await readProfile()
}

export async function bindPhone({ code, phone }) {
  if (!signedIn.value) throw new Error('请先登录')
  const version = profileVersion
  const result = demoMode ? demoUser(phone) : await client.request('phone_binding', { method: 'POST', data: { code } })
  if (!signedIn.value || version !== profileVersion) throw new Error('账号状态已更新，请重新查看资料')
  if (!result?.mobile || !result.user_no) throw new Error('未取得验证手机号，请重试')
  profileVersion++
  profile.value = result
  if (demoMode) save(result)
  return result
}

export function signOut() {
  entryScene = undefined
  return client.signOut()
}

export function noteEntry(options) {
  if (demoMode) return
  const scene = options?.query?.scene || options?.scene
  entryScene = scene ? String(scene).slice(0, 128) : undefined
  if (!entryScene || !signedIn.value) return
  const data = { scene: entryScene }
  entryScene = undefined
  // If the session expires, the API rejects this before recording the entry.
  client.request('entry_scenes', { method: 'POST', data }).catch(error => {
    if (error.code === 'confirmation_required') client.request('entry_scenes', { method: 'POST', data }).catch(() => {})
  })
}
