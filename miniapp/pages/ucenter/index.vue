<script setup>
import { computed, ref } from 'vue'
import { onShow, onTabItemTap } from '@dcloudio/uni-app'
import { handleTabShow, requestTabLogin } from '@/utils/guest-tab.js'
import { bindPhone, profile, readProfile, signedIn, signOut } from '@/store/session.js'
import { pageLinks } from '@/store/app-configuration.js'

const feedback = ref('')
const binding = ref(false)
async function load() {
  feedback.value = ''
  if (!signedIn.value) return
  try { await readProfile() }
  catch (error) { feedback.value = error.message || '资料读取失败，请重试' }
}

onShow(() => {
  handleTabShow('/pages/ucenter/index')
  load()
})
onTabItemTap(() => requestTabLogin('/pages/ucenter/index'))

const services = computed(() => pageLinks.value.profile_menu)
const region = computed(() => {
  const area = profile.value?.region || {}
  return [...new Set([area.country, area.province, area.city].filter(Boolean))].join(' ')
})

async function verifyPhone(result) {
  if (binding.value) return
  binding.value = true
  try {
    await bindPhone(result)
    feedback.value = ''
  } catch (error) {
    feedback.value = error.message || '手机号验证失败，请重试'
  } finally {
    binding.value = false
  }
}

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
      signOut().catch(() => uni.showToast({ title: '已退出，将在联网后补办注销', icon: 'none' }))
      uni.switchTab({ url: '/pages/index/index' })
    },
  })
}
</script>

<template>
  <view class="profile-page">
    <custom-page-header />
    <view class="user-heading">
      <image class="user-avatar" :src="profile?.avatar_url || '/static/ucenter/wechat-avatar.svg'" mode="aspectFit" />
      <view>
        <text>{{ profile?.nickname || '微信用户' }}</text>
        <view v-if="profile" class="user-detail">
          <text v-if="profile.user_no !== 'demo'">用户编号 {{ profile.user_no }}</text>
          <text v-if="region">地区 {{ region }}</text>
          <text v-if="profile.mobile">账号手机号 {{ profile.mobile }}</text>
          <custom-phone-authorization v-else label="绑定账号手机号" @authorized="verifyPhone"
            @denied="feedback = '已取消手机号授权'" @failed="feedback = '手机号授权失败，请重试'">
            <text>{{ binding ? '验证中…' : '绑定账号手机号' }}</text>
          </custom-phone-authorization>
        </view>
        <view v-if="feedback && signedIn" class="user-detail" aria-role="button" @tap="load">{{ feedback }}</view>
      </view>
    </view>
    <view v-if="services.length || signedIn" class="services-panel">
      <view class="services-title">就医服务</view>
      <view class="service-list">
        <custom-page-link v-for="service in services" :key="service.id" :link="service">
          <view class="service">
            <image v-if="service.image_url" class="service-icon" :src="service.image_url" mode="aspectFit" />
            <view v-else class="service-icon" aria-hidden="true" />
            <text>{{ service.name }}</text>
          </view>
        </custom-page-link>
        <view v-if="signedIn" class="service logout" aria-role="button" @tap="confirmLogout">
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
.user-detail { display: flex; flex-direction: column; gap: 4rpx; margin-top: 6rpx; color: #283f56; font-size: 25rpx; line-height: 40rpx; }
.services-panel { margin: 78rpx 32rpx 0; min-height: 326rpx; border-radius: 18rpx; background: #fff; padding: 30rpx 0 32rpx; box-sizing: border-box; }
.services-title { display: flex; align-items: center; gap: 12rpx; font-size: 32rpx; line-height: 48rpx; }
.services-title::before { content: ''; width: 8rpx; height: 30rpx; border-radius: 6rpx; background: #709af1; }
.service-list { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); row-gap: 32rpx; margin: 54rpx 28rpx 0; width: 85%; }
.service { display: flex; flex-direction: column; align-items: center; gap: 30rpx; font-size: 25rpx; line-height: 36rpx; text-align: center; overflow-wrap: anywhere; }
.service-icon { flex-shrink: 0; width: 68rpx; height: 66rpx; }
.logout-icon { position: relative; color: #686868; }
.door { position: absolute; left: 10rpx; top: 13rpx; width: 23rpx; height: 36rpx; border: 4rpx solid; border-right: 0; border-radius: 5rpx 0 0 5rpx; }
.arrow { position: absolute; left: 20rpx; top: 27rpx; width: 26rpx; height: 14rpx; border-radius: 2rpx; background: currentColor; }
.arrow::after { content: ''; position: absolute; top: -9rpx; right: -14rpx; border-block: 16rpx solid transparent; border-left: 18rpx solid currentColor; }
</style>
