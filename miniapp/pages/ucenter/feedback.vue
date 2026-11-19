<script setup>
import { computed, ref } from 'vue'
import { onUnload } from '@dcloudio/uni-app'
import { submitFeedback } from '@/mock/feedback.js'

const IMAGE_LIMIT = 3
const NOTICE_KEY = 'feedback-image-notice-seen'
const message = ref('')
const images = ref([])
const showNotice = ref(false)
const submission = ref('idle')
const submitting = computed(() => submission.value !== 'idle')
let noticeSeen = uni.getStorageSync(NOTICE_KEY) === true
let choosing = false
let unloaded = false

onUnload(() => {
  unloaded = true
  if (submission.value === 'pending') uni.hideLoading()
})

async function chooseImages() {
  if (choosing || submitting.value || images.value.length >= IMAGE_LIMIT) return
  choosing = true
  try {
    const { tapIndex } = await uni.showActionSheet({ itemList: ['拍摄', '从手机相册选择'] })
    const { tempFiles } = await uni.chooseMedia({
      count: IMAGE_LIMIT - images.value.length,
      mediaType: ['image'],
      sourceType: [tapIndex === 0 ? 'camera' : 'album'],
    })
    images.value.push(...tempFiles.map(file => file.tempFilePath))
  } catch (error) {
    if (!unloaded && !/cancel/i.test(error.errMsg ?? '')) {
      uni.showToast({ title: '未能添加图片，请重试', icon: 'none' })
    }
  } finally {
    choosing = false
  }
}

function addImages() {
  if (noticeSeen) return chooseImages()
  uni.hideKeyboard()
  showNotice.value = true
}

function dismissNotice(continuePicking) {
  showNotice.value = false
  noticeSeen = true
  // 只记录提示已展示，系统相册和相机权限由微信处理。
  uni.setStorage({ key: NOTICE_KEY, data: true })
  if (continuePicking) chooseImages()
}

async function submit() {
  if (submitting.value || !message.value.trim()) return
  submission.value = 'pending'
  uni.hideKeyboard()
  uni.showLoading({ title: '提交中', mask: true })
  try {
    await submitFeedback({ message: message.value, images: images.value })
  } catch {
    if (!unloaded) {
      submission.value = 'idle'
      uni.hideLoading()
      uni.showToast({ title: '提交失败，请重试', icon: 'error', duration: 2000 })
    }
    return
  }
  if (unloaded) return
  submission.value = 'complete'
  uni.hideLoading()
  uni.navigateBack({
    success: () => uni.showToast({ title: '模拟提交成功', icon: 'success', duration: 1500 }),
    fail: () => { submission.value = 'idle' },
  })
}
</script>

<template>
  <view class="feedback-page">
    <view class="feedback-header"><custom-page-header title="意见反馈" back /></view>
    <view class="feedback-form">
      <view class="feedback-label">反馈问题和意见<text class="required">*</text></view>
      <view class="feedback-card">
        <view v-if="showNotice" class="feedback-text">{{ message }}</view>
        <textarea v-else v-model="message" class="feedback-text" :disabled="submitting" :maxlength="260" aria-label="反馈问题和意见" />
        <view class="feedback-footer">
          <view class="image-list">
            <view v-for="(src, index) in images" :key="index" class="attachment">
              <image :src="src" class="thumbnail" mode="aspectFill" />
              <button class="remove-image" aria-label="移除图片" :disabled="submitting" @tap="images.splice(index, 1)">×</button>
            </view>
            <view v-if="images.length < IMAGE_LIMIT" class="add-image" aria-role="button" @tap="addImages">
              <text class="image-icon">&#xe696;</text><text>添加图片</text>
            </view>
          </view>
          <text class="character-count">{{ message.length }}/260</text>
        </view>
      </view>
    </view>
    <button class="feedback-submit" :disabled="submitting || !message.trim()" @tap="submit">确认提交</button>
    <view v-if="showNotice" class="notice-mask" @touchmove.stop.prevent>
      <view class="notice" aria-role="dialog" aria-label="反馈图片隐私说明">
        <view class="notice-title">反馈图片隐私说明</view>
        <view class="notice-copy">小程序只读取你主动选择或拍摄的照片，用于本次反馈。体验版图片仅在本机预览，不会发送给医院。</view>
        <view class="notice-tip">请遮挡照片中的姓名、手机号、病历号等个人信息。</view>
        <view class="notice-actions">
          <button class="notice-cancel" @tap="dismissNotice(false)">取消</button>
          <button class="notice-agree" @tap="dismissNotice(true)">同意</button>
        </view>
      </view>
    </view>
  </view>
</template>

<style scoped>
@font-face { font-family: feedback-icons; src: url('@/static/ucenter/feedback-icons.ttf') format('truetype'); }
.feedback-page { min-height: 100vh; color: #555; background: #f5f6f8; }
.feedback-header { background: #fff; }
.feedback-form { padding: 38rpx 32rpx; }
.feedback-label { font-size: 28rpx; line-height: 40rpx; }
.required { margin-left: 4rpx; color: #ba5054; }
.feedback-card { box-sizing: border-box; margin-top: 18rpx; padding: 26rpx; border-radius: 18rpx; background: #fff; }
.feedback-text { box-sizing: border-box; width: 100%; height: 300rpx; white-space: pre-wrap; color: #222; font-size: 28rpx; }
.feedback-footer { display: flex; align-items: flex-end; justify-content: space-between; }
.image-list { display: flex; flex-wrap: wrap; gap: 14rpx; }
.attachment { position: relative; }
.thumbnail { display: block; width: 130rpx; height: 130rpx; border-radius: 12rpx; }
.remove-image { position: absolute; top: -7rpx; right: -7rpx; margin: 0; padding: 0; width: 36rpx; height: 36rpx; line-height: 34rpx; border-radius: 50%; background: #555; color: #fff; font-size: 24rpx; }
.add-image { box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8rpx; width: 130rpx; height: 130rpx; border: 2rpx dashed #ccc; border-radius: 12rpx; background: #f9f9f9; font-size: 22rpx; }
.image-icon { color: #bbb; font: 46rpx/1 feedback-icons; }
.character-count { font-size: 28rpx; }
.feedback-submit { position: fixed; right: 35rpx; bottom: calc(env(safe-area-inset-bottom) + 36rpx); left: 35rpx; height: 64rpx; border-radius: 36rpx; background: #5ba6e7; color: white; font-size: 25rpx; line-height: 64rpx; }
.feedback-submit[disabled] { background: #c8c9cb; color: #686868; }
.feedback-submit::after { border: 0; }
.notice-mask { position: fixed; inset: 0; z-index: 10; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,.45); }
.notice { box-sizing: border-box; width: 528rpx; overflow: hidden; border-radius: 18rpx; background: #fff; color: #222; }
.notice-title { padding: 26rpx 32rpx 10rpx; text-align: center; font-weight: 600; font-size: 30rpx; line-height: 40rpx; }
.notice-copy, .notice-tip { padding: 0 32rpx; font-size: 26rpx; line-height: 37rpx; }
.notice-tip { padding-top: 10rpx; padding-bottom: 22rpx; color: #555; }
.notice-actions { display: flex; border-top: 1rpx solid #e8e8e8; }
.notice-actions button { flex: 1; margin: 0; padding: 0; border-radius: 0; background: #fff; font-size: 28rpx; line-height: 80rpx; }
.notice-actions button::after { border: 0; }
.notice-cancel { color: #666; }
.notice-agree { border-left: 1rpx solid #e8e8e8; color: #498fd1; }
</style>
