import { ref } from 'vue'
import { API_ORIGIN, wechatAppId, requestApp } from '../request/http.js'
import { createSessionClient } from '../request/session.js'
import { pauseApp } from '../utils/app-access.js'
import { deviceContext, entrySource } from '../utils/login-context.js'
import { configurationStatus, onAppDisabled } from './app-configuration.js'
import { createEntryQueue } from './entry-scenes.js'

const appId = wechatAppId()
export const demoMode = !appId
const storageKey = demoMode ? 'booking-demo-session' : 'booking-session:' + API_ORIGIN + ':' + appId
const saved = uni.getStorageSync(storageKey)
export const signedIn = ref(!!(demoMode ? saved?.user_no || saved?.phone : saved?.token))
const demoUser = mobile => ({ user_no: 'demo', nickname: '体验用户', mobile, booking_phone_required: false })
export const profile = ref(demoMode && signedIn.value ? demoUser(saved.mobile || saved.phone) : null)
let profileVersion = 0
let handlingAppDisabled = false
const entries = demoMode ? null : createEntryQueue({ storage: uni, sessionKey: storageKey, submit: postVisit })
if (saved?.token) {
  if (saved.user_no) entries?.activate(saved.user_no)
  else entries?.pruneSessions(saved.session_id)
} else {
  entries?.pruneSessions()
}

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
  // Let createSessionClient validate request freshness before pausing the app or retiring the session.
  send: (path, options) => requestApp(appId, path, options),
  changed: (active, detail) => {
    signedIn.value = active
    if (active) {
      if (client.userNo) entries?.activate(client.userNo, detail)
      else entries?.pruneSessions(client.pendingSessionId)
    } else {
      profileVersion++
      profile.value = null
      entries?.leave()
      if (detail === 'account_disabled') uni.showToast({ title: '账号已停用', icon: 'none' })
      if (detail === 'app_disabled' && !handlingAppDisabled) {
        handlingAppDisabled = true
        try { pauseApp() }
        finally { handlingAppDisabled = false }
      }
    }
  },
})

if (!demoMode) {
  // Configuration and private-endpoint disablement share the same session invalidation path.
  onAppDisabled(() => {
    if (handlingAppDisabled) return
    handlingAppDisabled = true
    try { client.signOut('app_disabled').catch(() => {}) }
    finally { handlingAppDisabled = false }
  })
}

export async function readProfile() {
  if (demoMode) return profile.value
  const version = profileVersion
  let result
  try {
    result = await client.request('me')
  } catch (error) {
    if (error && typeof error === 'object' && !error.stage) error.stage = 'profile'
    throw error
  }
  if (!result?.user_no) {
    const error = new Error('未取得本人资料，请重试')
    error.stage = 'profile'
    throw error
  }
  if (version !== profileVersion) throw new Error('登录状态已更新，请重试')
  profile.value = result
  return profile.value
}

export async function signIn() {
  if (demoMode) {
    profile.value ||= demoUser('')
    save(profile.value)
    signedIn.value = true
    return
  }
  if (configurationStatus.value === 'disabled') throw new Error('当前小程序已暂停服务')
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

export async function updateProfile({ nickname, avatarPath }) {
  if (!signedIn.value || demoMode) throw new Error('请先使用微信账号登录')
  const version = profileVersion
  const change = avatarPath ? { upload: { filePath: avatarPath, name: 'avatar' } } : { data: { nickname } }
  const result = await client.request('me', { ...change, method: 'PUT', expectedStatus: 200 })
  if (!signedIn.value || version !== profileVersion) throw new Error('账号状态已更新，请重新查看资料')
  if (!result?.user_no || result.user_no !== client.userNo || (avatarPath ? !result.avatar_url : result.nickname !== nickname)) {
    throw new Error('资料未获确认，请重新查看')
  }
  profileVersion++
  profile.value = result
}

export function signOut() {
  return client.signOut()
}

export function retryRevocations() {
  if (!demoMode) client.retryRevocations().catch(() => {})
}

export function retryEntryReports() {
  if (!signedIn.value || !entries) return
  if (client.userNo) {
    entries.retry().catch(() => {})
  } else if (entries.hasPendingSession(client.pendingSessionId)) {
    client.ensurePendingSession()
    identifyAndFlushEntries().catch(() => {})
  }
}

async function identifyAndFlushEntries() {
  const version = profileVersion
  const owner = await client.identifySavedSession()
  if (!owner || owner !== client.userNo || version !== profileVersion) return
  if (entries.pending) await entries.retry()
}

export async function noteEntry(options) {
  if (demoMode) return
  const entry = entrySource(options)
  if (!signedIn.value) {
    entries.add(entry)
    return
  }
  if (client.userNo) {
    entries.add(entry)
    try {
      if (entries.pending) await entries.retry()
      else await postVisit({ intended_user_no: client.userNo })
    } catch { /* A pending source is retried on the next foreground entry or reconnection. */ }
    return
  }
  const version = profileVersion
  if (entry || entries.hasPendingSession(client.pendingSessionId)) {
    const pendingSession = client.ensurePendingSession()
    if (pendingSession) entries.addForSession(pendingSession, entry)
  }
  try {
    // An older saved credential has no owner until its authenticated profile is read.
    const owner = await client.identifySavedSession()
    if (!owner || owner !== client.userNo || version !== profileVersion) return
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
