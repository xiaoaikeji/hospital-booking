function showNavigationError(error) {
  if (!error?.errMsg?.includes('cancel')) uni.showToast({ title: '暂时无法打开', icon: 'none' })
}

export function effectiveWebviewUrl({ id, status, links, openUrl }) {
  if (status === 'loading' || status === 'error') return openUrl
  if (status !== 'ready') return ''

  const link = Object.values(links).flat().find(item => String(item.id) === id && item.link_type === 'webview')
  return link?.url || ''
}

export function openPageLink(link) {
  const { link_type: type, url, params } = link
  const fail = showNavigationError

  switch (type) {
    case 'page':
      uni.navigateTo({ url, fail })
      break
    case 'tab':
      uni.switchTab({ url, fail })
      break
    case 'webview':
      uni.navigateTo({ url: '/pages/common/webview?id=' + encodeURIComponent(link.id), fail })
      break
    case 'miniprogram': {
      const query = Object.entries(params.query ?? {}).map(([key, value]) =>
        encodeURIComponent(key) + '=' + encodeURIComponent(value)).join('&')
      const path = (url ?? '').replace(/^\//, '')
      uni.navigateToMiniProgram({ appId: params.target_appid, path: query ? `${path}?${query}` : path, fail })
      break
    }
  }
}
