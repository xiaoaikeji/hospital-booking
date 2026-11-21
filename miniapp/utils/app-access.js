import { configurationStatus, refreshAppConfiguration } from '@/store/app-configuration.js'

export const PAUSED_PAGE = 'pages/common/service_paused'
const HOME_PAGE = 'pages/index/index'
let reopening = false

function showAccessPage() {
  const pages = getCurrentPages()
  const route = pages[pages.length - 1]?.route
  if (!route || reopening) return

  const disabled = configurationStatus.value === 'disabled'
  let destination
  if (disabled && route !== PAUSED_PAGE) destination = PAUSED_PAGE
  if (['ready', 'demo', 'error'].includes(configurationStatus.value) && route === PAUSED_PAGE) destination = HOME_PAGE
  if (!destination) return

  reopening = true
  uni.reLaunch({
    url: '/' + destination,
    complete() {
      reopening = false
      if (disabled !== (configurationStatus.value === 'disabled')) showAccessPage()
    },
  })
}

export function checkAppAccess() {
  showAccessPage()
  return refreshAppConfiguration().then(showAccessPage)
}

export async function canUseApp() {
  await checkAppAccess()
  return configurationStatus.value !== 'disabled'
}
