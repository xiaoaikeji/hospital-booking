<script setup>
import { ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { startDemoSession } from '@/mock/session.js'
import { leaveLogin, resumeBooking } from '@/utils/booking-navigation.js'

const feedback = ref('')
let target = {}
let leaving = false
onLoad(options => { target = options })

function authorize(result) {
  if (leaving) return
  if (!result.phone) {
    feedback.value = '已同意手机号授权。手机号验证和登录服务尚未开通。'
    return
  }
  try {
    startDemoSession(result.phone)
  } catch {
    feedback.value = '体验登录失败，请重试。'
    return
  }
  leaving = true
  resumeBooking(target)
}

function authorizationFailed() {
  if (leaving) return
  feedback.value = '暂时无法完成手机号授权，请重试。'
}

function authorizationCanceled() {
  if (leaving) return
  leaving = true
  leaveLogin()
}
</script>

<template>
  <view class="login-page">
    <custom-page-header title="授权登录" back />
    <view class="login-content">
      <image class="hospital-logo" src="/static/ucenter/hospital-logo.jpg" mode="aspectFit" aria-label="医院标志" />
      <view class="permission">
        <text class="permission-title">微信手机号授权</text>
        <text class="permission-note">申请获取你在微信中选择的手机号，用于预约服务。</text>
        <custom-phone-authorization label="授权手机号" @authorized="authorize" @denied="authorizationCanceled" @failed="authorizationFailed">
          <view class="login-button">授权手机号</view>
        </custom-phone-authorization>
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
.permission-result { display: block; margin-top: 24rpx; color: #536777; font-size: 26rpx; line-height: 38rpx; }
</style>
