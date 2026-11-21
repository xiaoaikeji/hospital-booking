<script setup>
import { ref } from 'vue'
import { onLoad, onUnload } from '@dcloudio/uni-app'
import { demoMode, signIn } from '@/store/session.js'
import { resumeBooking } from '@/utils/booking-navigation.js'

const feedback = ref('')
const busy = ref(false)
let target = {}
let leaving = false
onLoad(options => { target = options })
onUnload(() => { leaving = true })

async function login() {
  if (busy.value || leaving) return
  busy.value = true
  feedback.value = ''
  try {
    await signIn()
    if (!leaving) resumeBooking(target)
  } catch (error) {
    feedback.value = error.message || '登录失败，请重试'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <view class="login-page">
    <custom-page-header title="授权登录" back />
    <view class="login-content">
      <image class="hospital-logo" src="/static/ucenter/hospital-logo.jpg" mode="aspectFit" aria-label="医院标志" />
      <view class="permission">
        <text class="permission-title">{{ demoMode ? '预约体验' : '微信账号登录' }}</text>
        <text class="permission-note">登录后可查看本人资料，继续预约。</text>
        <button class="login-button" :disabled="busy" @tap="login">{{ busy ? '登录中…' : demoMode ? '体验登录' : '微信登录' }}</button>
        <text v-if="feedback" class="permission-result" role="status">{{ feedback }}</text>
      </view>
    </view>
  </view>
</template>

<style scoped>
.login-content { padding: 88rpx 60rpx 0; text-align: center; }
.hospital-logo { display: block; width: 348rpx; height: 348rpx; margin: 0 auto; }
.permission { margin-top: 40rpx; padding-top: 76rpx; border-top: 1rpx solid #e6e6e6; }
.permission-title, .permission-note { display: block; }
.permission-title { color: #333; font-size: 29rpx; line-height: 44rpx; }
.permission-note { margin-top: 19rpx; color: #999; font-size: 24rpx; line-height: 36rpx; }
.login-button { width: 100%; height: 70rpx; margin-top: 84rpx; border-radius: 35rpx; background: #5ba6e7; color: #fff; font-size: 27rpx; line-height: 70rpx; }
.login-button::after { border: 0; }
.permission-result { display: block; margin-top: 24rpx; color: #536777; font-size: 26rpx; line-height: 38rpx; }
</style>
