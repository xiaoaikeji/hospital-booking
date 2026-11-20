import { session } from '@/mock/session.js'

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
  if (session.value || openingLogin || publicEntry === url) return
  clearTimeout(loginTimer)
  loginTimer = setTimeout(() => {
    const pages = getCurrentPages()
    if (session.value || '/' + pages[pages.length - 1]?.route !== url) return
    openingLogin = true
    uni.navigateTo({ url: '/pages/ucenter/login', complete: () => { openingLogin = false } })
  }, 0)
}
