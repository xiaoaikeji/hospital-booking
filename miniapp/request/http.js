// 联调时填写后台域名，例如 https://example.com。留空时使用本地默认配置。
const API_ORIGIN = ''

export function loadAppConfiguration(onSuccess) {
  if (!API_ORIGIN) return
  const { appId } = uni.getAccountInfoSync().miniProgram
  if (!appId || appId === 'touristappid') return

  uni.request({
    url: API_ORIGIN + '/api/apps/wechat/' + encodeURIComponent(appId) + '/configuration',
    success({ statusCode, data }) {
      if (statusCode === 200) onSuccess(data)
    },
  })
}
