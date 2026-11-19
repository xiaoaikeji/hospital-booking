<script setup>
const services = [
  { label: '预约记录', icon: 'registration' },
  { label: '意见反馈', icon: 'appointment' },
  { label: '了解我院', icon: 'experts' },
]
</script>

<template>
  <view class="profile-page">
    <custom-page-header />
    <view class="user-heading">
      <image class="user-avatar" src="/static/ucenter/wechat-avatar.svg" mode="aspectFit" />
      <text>微信用户</text>
    </view>
    <view class="services-panel">
      <view class="services-title">就医服务</view>
      <view class="service-list">
        <view v-for="service in services" :key="service.icon" class="service">
          <image class="service-icon" :src="'/static/home/' + service.icon + '.svg'" mode="aspectFit" />
          <text>{{ service.label }}</text>
        </view>
      </view>
    </view>
  </view>
</template>

<style scoped>
.profile-page { min-height: 100vh; background: linear-gradient(180deg,#97bee0 0%,#f4f4f6 78%); color: #111; }
.user-heading { display: flex; align-items: center; gap: 20rpx; margin: 38rpx 60rpx 0; color: #fff; font-size: 46rpx; }
.user-avatar { width: 120rpx; height: 120rpx; }
.services-panel { margin: 78rpx 32rpx 0; min-height: 326rpx; border-radius: 18rpx; background: #fff; padding-top: 30rpx; box-sizing: border-box; }
.services-title { display: flex; align-items: center; gap: 12rpx; font-size: 32rpx; line-height: 48rpx; }
.services-title::before { content: ''; width: 8rpx; height: 30rpx; border-radius: 6rpx; background: #709af1; }
.service-list { display: grid; grid-template-columns: repeat(4, 1fr); margin: 54rpx 28rpx 0; width: 85%; }
.service { display: flex; flex-direction: column; align-items: center; gap: 30rpx; font-size: 25rpx; line-height: 36rpx; }
.service-icon { width: 68rpx; height: 66rpx; }
</style>
