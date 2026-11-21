<script setup>
import { ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { findDoctor } from '@/mock/doctors.js'
import { canOpenBooking, openBooking } from '@/utils/booking-navigation.js'

const doctor = ref(null)
let bookingParams
onLoad(async options => {
  if (!await canOpenBooking('doctor', options)) return
  doctor.value = findDoctor(options.id)
  bookingParams = options
})

function book() {
  openBooking('form', bookingParams)
}
</script>

<template>
  <view class="profile">
    <view class="header"><custom-page-header title="医生主页" back /></view>
    <view v-if="doctor" class="profile-content">
      <view class="profile-card" aria-role="link" :aria-label="'预约' + doctor.name" @tap="book">
        <view class="identity">
          <view class="summary">
            <image class="portrait" :src="doctor.portrait" mode="aspectFill" />
            <view class="credentials">
              <view class="name-line"><text>{{ doctor.name }}</text><text class="rank">{{ doctor.title }}</text></view>
              <text v-for="line in doctor.credentials" :key="line" class="credential">{{ line }}</text>
            </view>
          </view>
          <view class="visits">接诊量: <text>{{ doctor.visits }}</text></view>
        </view>
        <view class="details">
          <view class="section-title">专业擅长</view>
          <view class="description">{{ doctor.introduction }}</view>
          <view class="section-title">个人简介</view>
          <view class="description">{{ doctor.biography }}</view>
        </view>
      </view>
      <button class="book" hover-class="none" @tap="book">立即预约</button>
    </view>
    <view v-else class="unavailable">暂无该医生信息</view>
  </view>
</template>

<style scoped>
.profile { min-height: 100vh; display: flex; flex-direction: column; color: #111; }
.header { position: sticky; z-index: 1; top: 0; background: #f8f8f8; }
.profile-content { flex: 1; padding: 32rpx 32rpx calc(174rpx + env(safe-area-inset-bottom)); background: linear-gradient(180deg,#b0d5f3,#f4f4f6 70%); }
.profile-card { overflow: hidden; border-radius: 18rpx; background: #f8f8f8; }
.identity { padding: 22rpx 18rpx; background: linear-gradient(90deg,#f8f9fa,#a2ccef); }
.summary { display: flex; align-items: center; gap: 22rpx; margin: 0 4rpx; }
.portrait { flex: none; width: 160rpx; height: 160rpx; border-radius: 50%; }
.credentials { min-width: 0; }
.name-line { display: flex; align-items: center; gap: 18rpx; font-size: 36rpx; margin-bottom: 10rpx; }
.rank { padding: 0 11rpx; border-radius: 8rpx; background: #f7efdf; color: #896a49; font-size: 24rpx; line-height: 40rpx; }
.credential { display: block; font-size: 24rpx; line-height: 34rpx; color: #606971; }
.visits { margin-top: 20rpx; border-radius: 8rpx; text-align: center; background: rgba(255,255,255,.62); font-size: 23rpx; line-height: 56rpx; }
.visits text { color: #dfa747; font-weight: 600; }
.details { padding: 30rpx 32rpx 62rpx; }
.section-title { display: flex; align-items: center; gap: 18rpx; margin: 34rpx 0 24rpx; color: #64a8d8; font-size: 28rpx; line-height: 42rpx; }
.section-title::before { content: ''; box-sizing: border-box; width: 34rpx; height: 34rpx; border: 5rpx solid #62a9df; border-radius: 50%; }
.description { color: #666; font-size: 24rpx; line-height: 46rpx; }
.book { position: fixed; left: 52rpx; right: 52rpx; bottom: calc(50rpx + env(safe-area-inset-bottom)); border-radius: 16rpx; color: #fff; background: #5da6e6; font-size: 26rpx; line-height: 68rpx; }
.book::after { border: 0; }
.unavailable { padding: 40rpx; text-align: center; color: #888; }
</style>
