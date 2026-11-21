<script setup>
import { ref, watch } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { configurationStatus, pageLinks } from '@/store/app-configuration.js'
import { checkAppAccess } from '@/utils/app-access.js'
import { effectiveWebviewUrl } from '@/utils/page-link.js'

const id = ref('')
const openUrl = ref('')
const webviewFailed = ref(false)

watch([configurationStatus, pageLinks, id], ([status, links, id]) => {
  const url = effectiveWebviewUrl({ status, links, id, openUrl: openUrl.value })
  if (url === openUrl.value) return
  webviewFailed.value = false
  openUrl.value = url
})

onLoad(options => {
  // 每次直达先发起读取，避免用其他页面缓存的配置提前打开网页。
  checkAppAccess()
  id.value = options.id ?? ''
})

async function retry() {
  await checkAppAccess()
  if (configurationStatus.value === 'ready') webviewFailed.value = false
}
</script>

<template>
  <web-view v-if="openUrl && !webviewFailed" :src="openUrl" @error="webviewFailed = true" />
  <custom-service-paused v-else-if="configurationStatus === 'disabled'" />
  <view v-else class="webview-status">
    <text v-if="configurationStatus === 'loading'">正在读取网页配置…</text>
    <template v-else-if="configurationStatus === 'error' || webviewFailed">
      <text>{{ webviewFailed ? '暂时无法加载网页' : '暂时无法读取网页配置' }}</text>
      <button class="webview-retry" @tap="retry">重试</button>
    </template>
    <text v-else>网页暂不可用</text>
  </view>
</template>

<style scoped>
.webview-status { padding: 64rpx 24rpx; color: #536777; text-align: center; }
.webview-retry { width: 220rpx; margin: 32rpx auto 0; border-radius: 35rpx; background: #5ba6e7; color: #fff; font-size: 27rpx; }
</style>
