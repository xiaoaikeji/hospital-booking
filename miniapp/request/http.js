// 在工程根目录的 .env.local 中设置后台地址。留空时可在游客模式预览外观。
const API_ORIGIN = (import.meta.env.VITE_BOOKING_API_ORIGIN || '').trim().replace(/\/+$/, '')

export function loadAppConfiguration(onSuccess) {
  if (!API_ORIGIN) return false
  const { appId } = uni.getAccountInfoSync?.()?.miniProgram ?? {}
  if (!appId || appId === 'touristappid') return false

  uni.request({
    url: API_ORIGIN + '/api/apps/wechat/' + encodeURIComponent(appId) + '/configuration',
    success({ statusCode, data }) {
      if (statusCode === 200) onSuccess(data)
    },
  })
  return true
}
