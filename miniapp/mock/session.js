import { ref } from 'vue'

// 仅供本地预约流程使用。真实登录需要服务端用微信凭证建立会话。
const STORAGE_KEY = 'booking-demo-session'
export const session = ref(uni.getStorageSync(STORAGE_KEY) || null)

export function startDemoSession(phone = '') {
  const account = { phone }
  uni.setStorageSync(STORAGE_KEY, account)
  session.value = account
}

export function endDemoSession() {
  uni.removeStorageSync(STORAGE_KEY)
  session.value = null
}
