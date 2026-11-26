<script setup>
import { onPullDownRefresh, onShow } from '@dcloudio/uni-app'
import { checkAppAccess } from '@/utils/app-access.js'
import { handleTabShow } from '@/utils/guest-tab.js'
import HomeFirst from './components/home_first.vue'

onShow(() => {
  handleTabShow('/pages/index/index')
  checkAppAccess()
})

onPullDownRefresh(async () => {
  try {
    await checkAppAccess()
  } finally {
    uni.stopPullDownRefresh()
  }
})
</script>

<template>
  <HomeFirst />
</template>
