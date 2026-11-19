<script setup>
import { onShow } from '@dcloudio/uni-app'
import { handleTabShow } from '@/utils/guest-tab.js'
import HomeFirst from './components/home_first.vue'

onShow(() => handleTabShow('/pages/index/index'))
</script>

<template>
  <HomeFirst />
</template>
