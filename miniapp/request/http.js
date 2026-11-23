import { API_ORIGIN, buildApiUrl } from '../config/api.js'

export { API_ORIGIN }

export function wechatAppId() {
  const { appId } = uni.getAccountInfoSync?.()?.miniProgram ?? {}
  return appId && appId !== 'touristappid' ? appId : ''
}

export function disabledResponse(appId, { statusCode, data }) {
  return statusCode === 403 && data?.provider === 'wechat' && data.appid === appId && data.status === 'disabled'
}

export function configurationResult(appId, { statusCode, data }) {
  if (data?.provider === 'wechat' && data.appid === appId) {
    if (disabledResponse(appId, { statusCode, data })) return { status: 'disabled' }
    const { home_banner, profile_menu } = data.links ?? {}
    if (statusCode === 200 && ['active', 'auditing'].includes(data.status)
        && Array.isArray(home_banner) && Array.isArray(profile_menu)) {
      return { status: 'ready', config: data }
    }
  }
  return { status: 'error' }
}

export function responseData(appId, response, expectedStatus) {
  if (response.statusCode >= 200 && response.statusCode < 300) {
    if (expectedStatus && response.statusCode !== expectedStatus) throw new Error('服务端尚未确认本次操作')
    return response.data
  }
  const error = new Error(response.data?.message || '服务暂不可用，请重试')
  error.statusCode = response.statusCode
  error.code = response.data?.code
  error.appDisabled = disabledResponse(appId, response)
  throw error
}

export async function requestApp(appId, path, { method = 'GET', data, token, expectedStatus } = {}) {
  if (!appId || !API_ORIGIN) throw new Error('请先配置当前小程序的后台地址')
  let response
  try {
    response = await uni.request({
      url: buildApiUrl(appId, path),
      method, data, timeout: 15000, header: token ? { Authorization: 'Bearer ' + token } : {},
    })
  } catch {
    throw new Error('网络连接失败，请重试')
  }
  return responseData(appId, response, expectedStatus)
}

export async function loadAppConfiguration() {
  if (!API_ORIGIN) return { status: 'demo' }

  try {
    const appId = wechatAppId()
    if (!appId) return { status: 'demo' }
    const response = await uni.request({
      url: buildApiUrl(appId, 'configuration'),
      timeout: 10000,
    })
    return configurationResult(appId, response)
  } catch {
    return { status: 'error' }
  }
}
