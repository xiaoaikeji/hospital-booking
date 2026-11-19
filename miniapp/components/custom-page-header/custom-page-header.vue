<script setup>
defineProps({
  title: { type: String, default: '' },
  back: Boolean,
})

const { statusBarHeight } = uni.getWindowInfo()
const capsule = uni.getMenuButtonBoundingClientRect()
const height = capsule.height ? capsule.height + 2 * (capsule.top - statusBarHeight) : 44

function goBack() {
  if (getCurrentPages().length > 1) uni.navigateBack()
  else uni.switchTab({ url: '/pages/index/index' })
}
</script>

<template>
  <view class="page-header" :style="{ paddingTop: statusBarHeight + 'px' }">
    <view class="header-row" :style="{ height: height + 'px' }">
      <view v-if="back" class="header-back" role="button" aria-label="返回" @tap="goBack"><view class="back-arrow" /></view>
      <text>{{ title }}</text>
    </view>
  </view>
</template>

<style scoped>
.page-header { padding-bottom: 4rpx; }
.header-row { position: relative; display: flex; align-items: center; justify-content: center; color: #101010; font-size: 30rpx; font-weight: 600; }
.header-back { position: absolute; inset: 0 auto 0 12rpx; display: flex; align-items: center; justify-content: center; width: 58rpx; }
.back-arrow { width: 17rpx; height: 17rpx; border-left: 3rpx solid; border-bottom: 3rpx solid; transform: rotate(45deg); }
</style>
