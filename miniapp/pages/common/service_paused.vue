<script setup>
import { onShow } from '@dcloudio/uni-app'
import { configurationStatus } from '@/store/app-configuration.js'

onShow(() => uni.hideHomeButton())
</script>

<template>
  <custom-service-paused v-if="configurationStatus === 'disabled'" />
</template>
