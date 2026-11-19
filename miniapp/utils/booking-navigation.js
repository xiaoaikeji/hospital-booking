import { session } from '@/mock/session.js'

const destinations = {
  schedule: '/pages/booking/schedule',
  doctor: '/pages/booking/doctor',
  form: '/pages/booking/form',
}
const login = '/pages/ucenter/login'

function destinationUrl(target, { id, date, clinic, department } = {}, requireLogin = false) {
  const query = []
  if (requireLogin) query.push('target=' + target)
  if (id) query.push('id=' + encodeURIComponent(id))
  if (date) query.push('date=' + encodeURIComponent(date))
  if (clinic) query.push('clinic=' + encodeURIComponent(clinic))
  if (department) query.push('department=1')
  return (requireLogin ? login : destinations[target]) + (query.length ? '?' + query.join('&') : '')
}

export function openBooking(target, params) {
  uni.navigateTo({ url: destinationUrl(target, params, !session.value) })
}

// 编译模式或分享链接也可能直接打开二级页。
export function canOpenBooking(target, params) {
  if (session.value) return true
  uni.redirectTo({ url: destinationUrl(target, params, true) })
  return false
}

export function leaveLogin() {
  if (getCurrentPages().length > 1) uni.navigateBack()
  else uni.switchTab({ url: '/pages/index/index' })
}

export function resumeBooking(params) {
  if (Object.prototype.hasOwnProperty.call(destinations, params.target)) {
    uni.redirectTo({ url: destinationUrl(params.target, params) })
  } else {
    // 底栏已经切换到目标页，只需移走授权页。
    leaveLogin()
  }
}
