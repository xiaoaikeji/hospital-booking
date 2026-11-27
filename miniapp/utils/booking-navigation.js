import { signedIn } from '@/store/session.js'
import { directoryDemoMode, findBookingDoctor } from '@/store/booking-directory.js'
import { canUseApp } from '@/utils/app-access.js'

export const NO_BOOKABLE_DEPARTMENT = '该医生暂无可预约科室'

const destinations = {
  schedule: '/pages/booking/schedule',
  doctor: '/pages/booking/doctor',
  form: '/pages/booking/form',
}
const login = '/pages/ucenter/login'

function destinationUrl(target, { id, date, clinic, department, department_id, demo } = {}, requireLogin = false) {
  const query = []
  if (requireLogin) query.push('target=' + target)
  if (id) query.push('id=' + encodeURIComponent(id))
  if (date) query.push('date=' + encodeURIComponent(date))
  if (clinic) query.push('clinic=' + encodeURIComponent(clinic))
  if (department) query.push('department=1')
  if (department_id) query.push('department_id=' + encodeURIComponent(department_id))
  if (demo === true || demo === '1') query.push('demo=1')
  return (requireLogin ? login : destinations[target]) + (query.length ? '?' + query.join('&') : '')
}

export function openBooking(target, params) {
  if (warnIfNoDepartment(target, params)) return
  uni.navigateTo({ url: destinationUrl(target, params, !signedIn.value) })
}

function warnIfNoDepartment(target, params = {}) {
  if (target !== 'form' || directoryDemoMode || params.demo === '1' || params.demo === true) return false
  if (findBookingDoctor(params.id, false)?.department_ids?.length !== 0) return false

  uni.showToast({ title: NO_BOOKABLE_DEPARTMENT, icon: 'none' })
  return true
}

// 编译模式或分享链接也可能直接打开二级页。
export async function canOpenBooking(target, params) {
  const page = getCurrentPages().slice(-1)[0]
  if (!await canUseApp() || getCurrentPages().slice(-1)[0] !== page) return false
  if (warnIfNoDepartment(target, params)) {
    if (getCurrentPages().length > 1) uni.navigateBack()
    else uni.redirectTo({ url: destinationUrl('doctor', params) })
    return false
  }
  if (signedIn.value) return true
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
