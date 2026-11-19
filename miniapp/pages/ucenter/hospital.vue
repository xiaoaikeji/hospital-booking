<script setup>
import { appName } from '@/store/app-configuration.js'
</script>

<template>
  <view class="hospital-page">
    <view class="hospital-header"><custom-page-header title="医院介绍" back /></view>
    <view class="hospital-name">{{ appName }}</view>
  </view>
</template>

<style scoped>
.hospital-page { min-height: 100vh; background: #f6f7f9; }
.hospital-header { background: #fff; }
.hospital-name { margin: 20rpx; padding: 32rpx 22rpx; border-radius: 18rpx; background: #fff; color: #101010; font-size: 35rpx; font-weight: 700; line-height: 48rpx; }
</style>
