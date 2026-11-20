<script setup>
import { onShow, onTabItemTap } from '@dcloudio/uni-app'
import { handleTabShow, requestTabLogin } from '@/utils/guest-tab.js'
import { endDemoSession, session } from '@/mock/session.js'

onShow(() => handleTabShow('/pages/ucenter/index'))
onTabItemTap(() => requestTabLogin('/pages/ucenter/index'))

const services = [
  { label: '预约记录', icon: 'registration', url: '/pages/ucenter/appointments' },
  { label: '意见反馈', icon: 'appointment', url: '/pages/ucenter/feedback' },
  { label: '了解我院', icon: 'experts', url: '/pages/ucenter/hospital' },
]

function confirmLogout() {
  uni.showModal({
    title: '温馨提示',
    content: '确定退出',
    cancelText: '知道了',
    cancelColor: '#bbbbbb',
    confirmText: '确定',
    confirmColor: '#63a9d9',
    success: ({ confirm }) => {
      if (!confirm) return
      endDemoSession()
      uni.switchTab({ url: '/pages/index/index' })
    },
  })
}
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
        <navigator v-for="service in services" :key="service.url" class="service" :url="service.url" hover-class="none">
          <image class="service-icon" :src="'/static/home/' + service.icon + '.svg'" mode="aspectFit" />
          <text>{{ service.label }}</text>
        </navigator>
        <view v-if="session" class="service logout" aria-role="button" @tap="confirmLogout">
          <view class="service-icon logout-icon"><view class="door" /><view class="arrow" /></view>
          <text>退出登录</text>
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
.logout-icon { position: relative; color: #686868; }
.door { position: absolute; left: 10rpx; top: 13rpx; width: 23rpx; height: 36rpx; border: 4rpx solid; border-right: 0; border-radius: 5rpx 0 0 5rpx; }
.arrow { position: absolute; left: 20rpx; top: 27rpx; width: 26rpx; height: 14rpx; border-radius: 2rpx; background: currentColor; }
.arrow::after { content: ''; position: absolute; top: -9rpx; right: -14rpx; border-block: 16rpx solid transparent; border-left: 18rpx solid currentColor; }
</style>
