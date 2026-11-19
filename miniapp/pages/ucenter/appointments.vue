<template>
  <view class="appointments-page">
    <view class="appointments-header"><custom-page-header title="预约记录" back /></view>
    <view class="empty-card">
      <image class="empty-illustration" src="/static/ucenter/empty-appointments.jpg" mode="aspectFit" />
      <text class="empty-message">暂无预约记录</text>
    </view>
  </view>
</template>

<style scoped>
.appointments-page { min-height: 100vh; background: #f8f8f8; }
.appointments-header { background: #fff; }
.empty-card { display: flex; flex-direction: column; align-items: center; box-sizing: border-box; margin: 30rpx; padding-top: 68rpx; min-height: 540rpx; border-radius: 16rpx; background: #fff; }
.empty-illustration { display: block; width: 372rpx; height: 333rpx; }
.empty-message { margin-top: 6rpx; color: #aaa; font-size: 30rpx; line-height: 46rpx; }
</style>
