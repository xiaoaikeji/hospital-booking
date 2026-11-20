import { ref } from 'vue'

// 仅供本地预约流程使用。真实登录需要服务端用微信凭证建立会话。
const STORAGE_KEY = 'booking-demo-session'
function accountForPhone(phone) {
  return typeof phone === 'string' && phone.trim() ? { phone: phone.trim() } : null
}

export const session = ref(accountForPhone(uni.getStorageSync(STORAGE_KEY)?.phone))

export function startDemoSession(phone) {
  const account = accountForPhone(phone)
  if (!account) throw new Error('暂未获取到手机号，请重试')
  uni.setStorageSync(STORAGE_KEY, account)
  session.value = account
}

export function endDemoSession() {
  uni.removeStorageSync(STORAGE_KEY)
  session.value = null
}
