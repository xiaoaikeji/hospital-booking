<script setup>
import { ref } from 'vue'

defineProps({ label: { type: String, required: true } })
const emit = defineEmits(['authorized', 'denied'])
const account = uni.getAccountInfoSync().miniProgram
const demo = !account.appId || account.appId === 'touristappid'
const showDemo = ref(false)
const demoPhone = '10000000000'

function chooseDemo(allow) {
  showDemo.value = false
  if (allow) emit('authorized', { phone: demoPhone })
  else emit('denied')
}

function receivePhone(event) {
  const { code, errMsg } = event.detail
  if (errMsg === 'getPhoneNumber:ok' && code) emit('authorized', { code })
  else emit('denied')
}
</script>

<template>
  <view>
    <view class="phone-trigger">
      <slot />
      <button v-if="demo" class="phone-hit" :aria-label="label" @tap="showDemo = true" />
      <button v-else class="phone-hit" :aria-label="label" open-type="getPhoneNumber" @getphonenumber="receivePhone" />
    </view>
    <view v-if="showDemo" class="phone-mask">
      <view class="phone-backdrop" @tap="chooseDemo(false)" @touchmove.stop.prevent />
      <view class="phone-sheet" aria-role="dialog" aria-label="体验手机号授权">
        <view class="app-name"><image class="app-logo" src="/static/ucenter/hospital-logo.jpg" />临汾西京眼耳鼻喉医院预约挂号</view>
        <view class="request">申请获取并验证你的手机号</view>
        <view class="purpose">本地模拟登录或注册</view>
        <button class="phone-choice" @tap="chooseDemo(true)">100****0000<text class="demo-label">体验号码</text></button>
        <button class="phone-refuse" @tap="chooseDemo(false)">不允许</button>
      </view>
    </view>
  </view>
</template>

<style scoped>
.phone-trigger { position: relative; }
.phone-hit { position: absolute; inset: 0; width: 100%; height: 100%; padding: 0; margin: 0; opacity: 0; }
.phone-mask { position: fixed; z-index: 12; inset: 0; display: flex; align-items: flex-end; background: rgba(0,0,0,.30); text-align: left; }
.phone-backdrop { position: absolute; inset: 0; }
.phone-sheet { position: relative; box-sizing: border-box; width: 100%; padding: 54rpx 42rpx calc(80rpx + env(safe-area-inset-bottom)); border-radius: 20rpx 20rpx 0 0; background: #f8f8f8; color: #111; animation: slide-in .22s ease-out; }
.app-name { display: flex; align-items: center; gap: 14rpx; font-size: 26rpx; font-weight: 600; }
.app-logo { width: 40rpx; height: 40rpx; }
.request { margin-top: 40rpx; font-size: 30rpx; font-weight: 600; }
.purpose { margin: 12rpx 0 42rpx; color: #888; font-size: 24rpx; }
.phone-choice, .phone-refuse { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 124rpx; margin-top: 20rpx; background: #fff; font-size: 29rpx; line-height: 42rpx; }
.demo-label { color: #999; font-size: 22rpx; }
.phone-choice::after, .phone-refuse::after { border: 0; }
@keyframes slide-in { from { transform: translateY(100%); } to { transform: translateY(0); } }
</style>
