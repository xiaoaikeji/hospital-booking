<script>
// 重新启动小程序时重置，同一进程从首页或个人中心进入只播放一次。
let firstVisit = true
</script>

<script setup>
import { ref } from 'vue'
import { onUnload } from '@dcloudio/uni-app'

const loading = ref(firstVisit)
let timer
if (firstVisit) {
  firstVisit = false
  timer = setTimeout(() => { loading.value = false }, 1500)
}
onUnload(() => clearTimeout(timer))
</script>

<template>
  <view class="appointments-page">
    <view class="appointments-header"><custom-page-header title="预约记录" back /></view>
    <view v-if="loading" class="record-loading" role="status">
      <view class="spinner">
        <view v-for="i in 12" :key="i" class="spoke" :style="{ transform: 'rotate(' + i * 30 + 'deg)', opacity: i / 12 }" />
      </view>
      <text>加载中...</text>
    </view>
    <view v-else class="empty-card">
      <image class="empty-illustration" src="/static/ucenter/empty-appointments.jpg" mode="aspectFit" />
      <text class="empty-message">暂无预约记录</text>
    </view>
  </view>
</template>

<style scoped>
.appointments-page { min-height: 100vh; background: #f8f8f8; }
.appointments-header { background: #fff; }
.record-loading { display: flex; align-items: center; justify-content: center; gap: 62rpx; padding-top: 72rpx; font-size: 28rpx; color: #111; }
.spinner { position: relative; width: 90rpx; height: 90rpx; animation: spin 1s steps(12) infinite; }
.spoke { position: absolute; inset: 0; }
.spoke::before { content: ''; display: block; margin: 0 auto; width: 10rpx; height: 22rpx; border-radius: 50%; background: #60aae4; }
@keyframes spin { to { transform: rotate(360deg); } }
.empty-card { display: flex; flex-direction: column; align-items: center; box-sizing: border-box; margin: 30rpx; padding-top: 68rpx; min-height: 540rpx; border-radius: 16rpx; background: #fff; }
.empty-illustration { display: block; width: 372rpx; height: 333rpx; }
.empty-message { margin-top: 6rpx; color: #aaa; font-size: 30rpx; line-height: 46rpx; }
</style>
