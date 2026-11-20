<script setup>
import { onLoad } from '@dcloudio/uni-app'
import { startDemoSession } from '@/mock/session.js'
import { leaveLogin, resumeBooking } from '@/utils/booking-navigation.js'

let target = {}
let leaving = false
onLoad(options => { target = options })

function authorize(result) {
  if (leaving) return
  try {
    startDemoSession(result?.phone)
  } catch {
    uni.showToast({ title: result?.phone ? '登录失败，请重试' : '暂未获取到手机号，请重试', icon: 'none' })
    return
  }
  leaving = true
  resumeBooking(target)
}
</script>

<template>
  <view class="login-page">
    <custom-page-header title="授权登录" back />
    <view class="login-content">
      <image class="hospital-logo" src="/static/ucenter/hospital-logo.jpg" mode="aspectFit" aria-label="医院标志" />
      <view class="permission">
        <text class="permission-title">申请获取以下权限</text>
        <text class="permission-note">获取你的公开信息(微信昵称、头像等) 授权登录</text>
        <custom-phone-authorization label="授权登录" @authorized="authorize" @denied="leaveLogin">
          <view class="login-button">授权登录</view>
        </custom-phone-authorization>
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
</style>
