<script setup>
import { computed } from 'vue'
import { onShow } from '@dcloudio/uni-app'
import { configurationStatus, hospitalProfile } from '@/store/app-configuration.js'
import { checkAppAccess } from '@/utils/app-access.js'

const hospital = hospitalProfile
const hasProfile = computed(() => Object.values(hospital.value).some(Boolean))
onShow(checkAppAccess)
</script>

<template>
  <view class="hospital-page">
    <view class="hospital-header"><custom-page-header title="医院介绍" back /></view>
    <view v-if="hasProfile" class="hospital-card">
      <view v-if="hospital.company_name" class="hospital-name">{{ hospital.company_name }}</view>
      <image v-if="hospital.image_url" class="hospital-image" :src="hospital.image_url" mode="widthFix" />
      <view v-if="hospital.address" class="hospital-field"><text>地址</text><text>{{ hospital.address }}</text></view>
      <view v-if="hospital.mobile" class="hospital-field"><text>电话</text><text>{{ hospital.mobile }}</text></view>
      <view v-if="hospital.time_range" class="hospital-field"><text>营业时间</text><text>{{ hospital.time_range }}</text></view>
      <view v-if="hospital.introduction" class="hospital-introduction">{{ hospital.introduction }}</view>
    </view>
    <view v-else class="hospital-card hospital-status" role="status">
      {{ configurationStatus === 'loading' ? '正在读取医院资料' : configurationStatus === 'error' ? '医院资料暂不可用' : '暂无医院资料' }}
    </view>
  </view>
</template>

<style scoped>
.hospital-page { min-height: 100vh; background: #f6f7f9; }
.hospital-header { background: #fff; }
.hospital-card { margin: 20rpx; padding: 32rpx 22rpx; border-radius: 18rpx; background: #fff; color: #333; font-size: 29rpx; line-height: 44rpx; }
.hospital-name { color: #101010; font-size: 35rpx; font-weight: 700; line-height: 48rpx; }
.hospital-image { display: block; width: 100%; margin-top: 20rpx; border-radius: 12rpx; }
.hospital-field { display: flex; gap: 16rpx; margin-top: 20rpx; }
.hospital-field text:first-child { flex: none; min-width: 115rpx; color: #666; }
.hospital-field text:last-child { min-width: 0; overflow-wrap: anywhere; }
.hospital-introduction { margin-top: 20rpx; white-space: pre-wrap; overflow-wrap: anywhere; }
.hospital-status { color: #666; }
</style>
