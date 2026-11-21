<script setup>
import { computed, ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { configurationStatus, pageLinks } from '@/store/app-configuration.js'
import { checkAppAccess } from '@/utils/app-access.js'

const id = ref('')
const webviewFailed = ref(false)
const page = computed(() => {
  if (configurationStatus.value !== 'ready') return null
  return Object.values(pageLinks.value).flat().find(link =>
    String(link.id) === id.value && link.link_type === 'webview' && link.url)
})

onLoad(options => { id.value = options.id ?? '' })

function retry() {
  webviewFailed.value = false
  checkAppAccess()
}
</script>

<template>
  <web-view v-if="page && !webviewFailed" :src="page.url" @error="webviewFailed = true" />
  <custom-service-paused v-else-if="configurationStatus === 'disabled'" />
  <view v-else class="webview-status">
    <text v-if="configurationStatus === 'loading'">正在读取网页配置…</text>
    <template v-else-if="configurationStatus === 'error' || (page && webviewFailed)">
      <text>{{ page ? '暂时无法加载网页' : '暂时无法读取网页配置' }}</text>
      <button class="webview-retry" @tap="retry">重试</button>
    </template>
    <text v-else>网页暂不可用</text>
  </view>
</template>

<style scoped>
.webview-status { padding: 64rpx 24rpx; color: #536777; text-align: center; }
.webview-retry { width: 220rpx; margin: 32rpx auto 0; border-radius: 35rpx; background: #5ba6e7; color: #fff; font-size: 27rpx; }
</style>
