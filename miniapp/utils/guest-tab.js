import { signedIn } from '@/store/session.js'
import { canUseApp } from '@/utils/app-access.js'

let activeTab = ''
let publicEntry = ''
let loginTimer
let openingLogin = false

export function switchFromHomeCard(url) {
  publicEntry = url
  uni.switchTab({ url, fail: () => { publicEntry = '' } })
}

export function handleTabShow(url) {
  const changed = activeTab !== url
  const fromHomeCard = publicEntry === url
  activeTab = url
  publicEntry = ''
  // 从二级页返回也会触发 onShow，此时仍是原来的底栏页。
  if (changed && !fromHomeCard && url !== '/pages/index/index') requestTabLogin(url)
}

export function requestTabLogin(url) {
  if (signedIn.value || openingLogin || publicEntry === url) return
  clearTimeout(loginTimer)
  loginTimer = setTimeout(async () => {
    if (!await canUseApp()) return
    const pages = getCurrentPages()
    if (signedIn.value || openingLogin || '/' + pages[pages.length - 1]?.route !== url) return
    openingLogin = true
    uni.navigateTo({ url: '/pages/ucenter/login', complete: () => { openingLogin = false } })
  }, 0)
}
