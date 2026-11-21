import { ref } from 'vue'
import { API_ORIGIN, wechatAppId, requestApp } from '../request/http.js'
import { createSessionClient } from '../request/session.js'
import { pauseApp } from '../utils/app-access.js'
import { deviceContext, entrySource } from '../utils/login-context.js'
import { createEntryQueue } from './entry-scenes.js'

const appId = wechatAppId()
export const demoMode = !appId
const storageKey = demoMode ? 'booking-demo-session' : 'booking-session:' + API_ORIGIN + ':' + appId
const saved = uni.getStorageSync(storageKey)
export const signedIn = ref(!!(demoMode ? saved?.user_no || saved?.phone : saved?.token))
const demoUser = mobile => ({ user_no: 'demo', nickname: '体验用户', mobile, booking_phone_required: false })
export const profile = ref(demoMode && signedIn.value ? demoUser(saved.mobile || saved.phone) : null)
let profileVersion = 0
const entries = demoMode ? null : createEntryQueue({ storage: uni, sessionKey: storageKey, submit: postVisit })
if (saved?.token) entries?.activate(saved.user_no)

function save(value) {
  if (value) uni.setStorageSync(storageKey, value)
  else uni.removeStorageSync(storageKey)
}

const client = createSessionClient({
  saved: demoMode ? null : saved,
  save, deviceContext,
  loginCode: async () => {
    try { return (await uni.login({ provider: 'weixin' })).code }
    catch { throw new Error('微信登录失败，请重试') }
  },
  send: async (path, options) => {
    try { return await requestApp(appId, path, options) }
    catch (error) {
      if (error.appDisabled) pauseApp()
      throw error
    }
  },
  changed: (active, reason) => {
    signedIn.value = active
    if (active) {
      entries?.activate(client.userNo)
    } else {
      profileVersion++
      profile.value = null
      entries?.leave()
      if (reason === 'account_disabled') uni.showToast({ title: '账号已停用', icon: 'none' })
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
  await client.signIn()
  try { await readProfile() }
  finally { retryEntryReports() }
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
  return client.signOut()
}

export function retryRevocations() {
  if (!demoMode) client.retryRevocations().catch(() => {})
}

export function retryEntryReports() {
  if (signedIn.value) entries?.retry().catch(() => {})
}

export async function noteEntry(options) {
  if (demoMode) return
  const entry = entrySource(options)
  if (!signedIn.value) {
    entries.add(entry)
    return
  }
  const version = profileVersion
  try {
    // An older saved credential has no owner until its authenticated profile is read.
    const owner = client.userNo || await client.identifySavedSession()
    if (!owner || owner !== client.userNo || version !== profileVersion) return
    entries.add(entry)
    if (entries.pending) await entries.retry()
    else await postVisit({ intended_user_no: client.userNo })
  } catch { /* A pending source is retried on the next foreground entry or reconnection. */ }
}

async function postVisit(entry) {
  const options = { method: 'POST', data: { ...deviceContext(), ...entry }, expectedStatus: 204 }
  try { await client.request('entry_scenes', options) }
  catch (error) {
    if (error.code !== 'confirmation_required' || client.userNo !== entry.intended_user_no) throw error
    await client.request('entry_scenes', options)
  }
}
