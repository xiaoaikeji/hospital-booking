// 在工程根目录的 .env.local 中设置后台地址。留空时可在游客模式预览外观。
const API_ORIGIN = (import.meta.env?.VITE_BOOKING_API_ORIGIN || '').trim().replace(/\/+$/, '')

export function wechatAppId() {
  const { appId } = uni.getAccountInfoSync?.()?.miniProgram ?? {}
  return appId && appId !== 'touristappid' ? appId : ''
}

export function configurationResult(appId, { statusCode, data }) {
  if (data?.provider === 'wechat' && data.appid === appId) {
    if (statusCode === 403 && data.status === 'disabled') return { status: 'disabled' }
    const { home_banner, profile_menu } = data.links ?? {}
    if (statusCode === 200 && ['active', 'auditing'].includes(data.status)
        && Array.isArray(home_banner) && Array.isArray(profile_menu)) {
      return { status: 'ready', config: data }
    }
  }
  return { status: 'error' }
}

export async function loadAppConfiguration() {
  if (!API_ORIGIN) return { status: 'demo' }

  try {
    const appId = wechatAppId()
    if (!appId) return { status: 'demo' }
    const response = await uni.request({
      url: API_ORIGIN + '/api/apps/wechat/' + encodeURIComponent(appId) + '/configuration',
      timeout: 10000,
    })
    return configurationResult(appId, response)
  } catch {
    return { status: 'error' }
  }
}
