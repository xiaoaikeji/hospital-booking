let activeTab = ''
let publicEntry = ''

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
  if (!changed || fromHomeCard || url === '/pages/index/index') return
  setTimeout(() => {
    const pages = getCurrentPages()
    if ('/' + pages[pages.length - 1]?.route === url) {
      uni.navigateTo({ url: '/pages/ucenter/login' })
    }
  }, 0)
}
