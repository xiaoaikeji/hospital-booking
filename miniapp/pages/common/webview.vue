<script setup>
import { computed, ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { appConfiguration, pageLinks } from '@/store/app-configuration.js'

const id = ref('')
const page = computed(() => Object.values(pageLinks.value).flat().find(link =>
  String(link.id) === id.value && link.link_type === 'webview'))

onLoad(options => { id.value = options.id ?? '' })
</script>

<template>
  <web-view v-if="page" :src="page.url" />
  <view v-else-if="appConfiguration" class="webview-unavailable">网页暂不可用</view>
</template>

<style scoped>
.webview-unavailable { padding: 64rpx 24rpx; color: #536777; text-align: center; }
</style>
