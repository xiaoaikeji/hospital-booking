<script setup>
import { computed, ref, watch } from 'vue'
import { onHide, onShow, onTabItemTap } from '@dcloudio/uni-app'
import { handleTabShow, requestTabLogin } from '@/utils/guest-tab.js'
import { demoMode, profile, readProfile, signedIn, signOut, updateProfile } from '@/store/session.js'
import { pageLinks } from '@/store/app-configuration.js'

const myPage = '/pages/ucenter/index'
const defaultAvatar = '/static/ucenter/wechat-avatar.svg'
const failedAvatar = ref('')
const choosingNickname = ref(false)
const nicknameDraft = ref('')
const pendingNickname = ref('')
let profileSave = Promise.resolve()
const saving = ref(false)
const canEdit = computed(() => signedIn.value && !demoMode)
const displayName = computed(() => (canEdit.value && (profile.value?.display_name || profile.value?.nickname)) || '微信用户')
const avatar = computed(() => canEdit.value && profile.value?.avatar_url || '')
const avatarInitial = computed(() => profile.value?.avatar_initial || Array.from(displayName.value)[0])

onShow(() => {
  handleTabShow(myPage)
  if (canEdit.value) {
    failedAvatar.value = ''
    readProfile().catch(() => {}) // An offline refresh keeps the last confirmed profile.
  }
})
onTabItemTap(() => requestTabLogin(myPage))
onHide(closeNickname)
watch(() => profile.value?.user_no, closeNickname)

const services = computed(() => pageLinks.value.profile_menu)

function saveProfile(change) {
  const owner = profile.value?.user_no
  if (!canEdit.value || !owner) return
  // Closing the nickname keyboard can coincide with choosing a photo.
  profileSave = profileSave.then(async () => {
    if (!canEdit.value || profile.value?.user_no !== owner) return
    saving.value = true
    try {
      await updateProfile(change)
    } catch (error) {
      if (canEdit.value && profile.value?.user_no === owner) {
        uni.showToast({ title: error.message, icon: 'none' })
      }
    } finally {
      saving.value = false
    }
  })
}

function chooseAvatar(event) {
  const avatarPath = event.detail?.avatarUrl
  if (avatarPath) saveProfile({ avatarPath })
}

function chooseNickname() {
  if (choosingNickname.value || pendingNickname.value) return
  nicknameDraft.value = ''
  choosingNickname.value = true
}

function closeNickname() {
  choosingNickname.value = false
  pendingNickname.value = ''
}

function finishNickname(event) {
  if (!choosingNickname.value) return
  choosingNickname.value = false
  const nickname = (event.detail?.value ?? nicknameDraft.value).trim()
  if (!nickname || nickname === profile.value?.nickname) return
  if (uni.canIUse?.('input.bindnicknamereview')) pendingNickname.value = nickname
  else saveProfile({ nickname })
}

function nicknameReviewed({ detail }) {
  const nickname = pendingNickname.value
  pendingNickname.value = ''
  if (!nickname) return
  if (detail?.pass && !detail.timeout) saveProfile({ nickname })
  else {
    uni.showToast({ title: detail?.timeout ? '昵称检查超时，请重试' : '请重新选择昵称', icon: 'none' })
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
      <button v-if="canEdit" class="profile-avatar-button" open-type="chooseAvatar" hover-class="none" aria-label="更换头像"
        :disabled="saving || !profile" @chooseavatar="chooseAvatar">
        <image v-if="avatar && avatar !== failedAvatar" class="user-avatar" :src="avatar" mode="aspectFill" @error="failedAvatar = avatar" />
        <text v-else class="user-avatar profile-monogram" aria-hidden="true">{{ avatarInitial }}</text>
      </button>
      <image v-else class="user-avatar" :src="defaultAvatar" mode="aspectFit" @tap="requestTabLogin(myPage)" />
      <button v-if="canEdit" class="profile-name" hover-class="none" aria-label="选择微信昵称"
        :disabled="saving || !!pendingNickname || !profile" @tap="chooseNickname">{{ (choosingNickname && nicknameDraft) || displayName }}</button>
      <text v-else-if="demoMode && signedIn" class="profile-name">{{ displayName }}</text>
      <button v-else class="profile-name" hover-class="none" aria-label="微信登录" @tap="requestTabLogin(myPage)">{{ displayName }}</button>
    </view>
    <!-- WeChat presents nickname suggestions when this native input receives focus after a tap. -->
    <input v-if="canEdit && (choosingNickname || pendingNickname)" v-model="nicknameDraft" class="nickname-keyboard" type="nickname"
      aria-label="选择或填写昵称" confirm-type="done" :maxlength="100" :focus="choosingNickname" :adjust-position="false"
      @blur="finishNickname" @nicknamereview="nicknameReviewed" />
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
.user-avatar, .profile-avatar-button { display: block; width: 120rpx; height: 120rpx; flex-shrink: 0; border-radius: 50%; }
.user-avatar.profile-monogram { display: flex; align-items: center; justify-content: center; background: #e9f3fb; color: #316790; font-size: 52rpx; font-weight: 600; line-height: 1; }
.user-heading button { margin: 0; padding: 0; background: transparent; color: inherit; line-height: inherit; }
.user-heading button::after { border: 0; }
.profile-name { min-width: 0; max-width: 100%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font-size: inherit; text-align: left; }
.nickname-keyboard { position: fixed; top: 0; left: 0; width: 1px; height: 1px; min-height: 0; opacity: 0; pointer-events: none; }
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
