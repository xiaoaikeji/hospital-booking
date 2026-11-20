<script setup>
import { ref } from 'vue'

const props = defineProps({ patients: { type: Array, required: true }, selected: String })
const emit = defineEmits(['cancel', 'confirm', 'add'])
const choice = ref(props.selected || '')
</script>

<template>
  <view class="mask">
    <view class="backdrop" @tap="emit('cancel')" @touchmove.stop.prevent />
    <view class="sheet" aria-role="dialog" aria-label="选择就诊人">
      <view class="sheet-title">选择就诊人</view>
      <scroll-view scroll-y class="list">
        <view v-for="patient in patients" :key="patient.id" class="patient" aria-role="button" @tap="choice = patient.id">
          <view><view>{{ patient.name }}</view><text class="meta">{{ patient.sex }} · {{ patient.age }}岁</text></view>
          <view class="radio" :class="{ active: choice === patient.id }">{{ choice === patient.id ? '✓' : '' }}</view>
        </view>
      </scroll-view>
      <button class="add" @tap="emit('add')">＋ 新增就诊人</button>
      <view class="actions">
        <button class="cancel" @tap="emit('cancel')">取消</button>
        <button class="confirm" :disabled="!choice" @tap="emit('confirm', choice)">确定</button>
      </view>
    </view>
  </view>
</template>

<style scoped>
.mask { position: fixed; z-index: 8; inset: 0; display: flex; align-items: flex-end; background: rgba(0,0,0,.4); }
.backdrop { position: absolute; inset: 0; }
.sheet { position: relative; width: 100%; padding: 30rpx 30rpx calc(24rpx + env(safe-area-inset-bottom)); box-sizing: border-box; border-radius: 24rpx 24rpx 0 0; color: #111; background: white; animation: slide-up .22s ease-out; }
.sheet-title { text-align: center; font-size: 32rpx; font-weight: 600; padding-bottom: 22rpx; }
.list { max-height: 45vh; }
.patient { display: flex; align-items: center; justify-content: space-between; padding: 20rpx 6rpx; border-top: 1rpx solid #eee; }
.meta { color: #777; font-size: 24rpx; }
.radio { width: 34rpx; height: 34rpx; line-height: 34rpx; border: 2rpx solid #ccc; border-radius: 50%; text-align: center; }
.radio.active { color: white; background: #5ba7e5; border-color: #5ba7e5; }
.add { margin: 8rpx 0 18rpx; font-size: 27rpx; color: #458dc4; background: white; }
.add::after, .confirm::after { border: 0; }
.actions { display: flex; gap: 16rpx; }
.actions button { margin: 0; font-size: 28rpx; line-height: 76rpx; }
.cancel { flex: 1; background: white; }
.confirm { flex: 2; background: #5ba7e5; color: white; }
.confirm[disabled] { background: #d8d8d8; color: white; }
@keyframes slide-up { from { transform: translateY(100%); } to { transform: translateY(0); } }
</style>
