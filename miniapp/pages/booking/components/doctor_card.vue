<script setup>
defineProps({ doctor: { type: Object, required: true } })
</script>

<template>
  <view class="doctor-card">
    <view class="doctor-summary">
      <image class="doctor-portrait" :src="doctor.portrait" mode="aspectFill" :aria-label="doctor.name" />
      <view class="doctor-text">
        <view class="doctor-heading">
          <text class="doctor-name">{{ doctor.name }}</text>
          <text class="doctor-rank">{{ doctor.title }}</text>
        </view>
        <text v-for="line in doctor.credentials" :key="line" class="credential">{{ line }}</text>
      </view>
      <text class="booking-action">预约</text>
    </view>
    <view class="specialty">
      <view class="specialty-summary"><text class="specialty-label">【擅长】</text>：{{ doctor.introduction }}</view>
      <view class="specialty-arrow" />
    </view>
  </view>
</template>

<style scoped>
.doctor-card { position: relative; margin-top: 20rpx; padding: 22rpx 22rpx 24rpx; border-radius: 18rpx; background: #fff; }
.doctor-summary { display: flex; align-items: flex-start; gap: 20rpx; }
.doctor-portrait { flex: none; width: 120rpx; height: 120rpx; border-radius: 50%; }
.doctor-text { min-width: 0; flex: 1; }
.doctor-heading { display: flex; align-items: center; flex-wrap: wrap; gap: 18rpx; padding-right: 102rpx; min-height: 44rpx; margin-bottom: 7rpx; }
.doctor-name { font-size: 30rpx; line-height: 44rpx; }
.doctor-rank { border-radius: 8rpx; padding: 0 10rpx; color: #896a49; background: #f7efdf; font-size: 23rpx; line-height: 40rpx; }
.credential { display: block; font-size: 24rpx; line-height: 34rpx; font-weight: 300; color: #666; }
.booking-action { position: absolute; top: 18rpx; right: 20rpx; border-radius: 32rpx; padding: 0 26rpx; color: #fff; background: linear-gradient(90deg,#70b4ed,#90c4ed); font-size: 27rpx; line-height: 50rpx; }
.specialty { display: flex; align-items: center; justify-content: space-between; gap: 27rpx; padding-right: 8rpx; margin-top: 22rpx; }
.specialty-summary { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; font-size: 24rpx; line-height: 36rpx; }
.specialty-label { color: #68aada; }
.specialty-arrow { flex: none; width: 0; height: 0; border-inline: 12rpx solid transparent; border-top: 14rpx solid #9bc9e7; }
</style>
