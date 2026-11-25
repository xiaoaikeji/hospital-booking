<script setup>
import { computed, ref } from 'vue'

const props = defineProps({
  patients: { type: Array, required: true },
  selected: String,
  loading: Boolean,
  loadError: Boolean,
})
const emit = defineEmits(['cancel', 'confirm', 'add', 'edit', 'retry'])
const choice = ref(props.selected || '')
const hasChoice = computed(() => props.patients.some(patient => patient.id === choice.value))
</script>

<template>
  <view class="mask">
    <view class="backdrop" @tap="emit('cancel')" @touchmove.stop.prevent />
    <view class="sheet" aria-role="dialog" aria-label="选择就诊人">
      <view class="sheet-title">选择就诊人</view>
      <view v-if="loadError" class="status" aria-role="button" @tap="emit('retry')">名单读取失败，点此重试</view>
      <view v-else-if="loading" class="status">正在读取常用就诊人…</view>
      <view v-else-if="!patients.length" class="status">暂无常用就诊人</view>
      <scroll-view scroll-y class="list">
        <view v-for="patient in patients" :key="patient.id" class="patient">
          <view class="select-patient" aria-role="button" @tap="choice = patient.id">
            <view class="patient-info"><view>{{ patient.name }}</view><text class="meta">{{ patient.sex }} · {{ patient.age }}岁</text></view>
            <view class="radio" :class="{ active: choice === patient.id }">{{ choice === patient.id ? '✓' : '' }}</view>
          </view>
          <button class="edit" hover-class="none" @tap="emit('edit', patient.id)">编辑</button>
        </view>
      </scroll-view>
      <button class="add" @tap="emit('add')">＋ 新增就诊人</button>
      <view class="actions">
        <button class="cancel" @tap="emit('cancel')">取消</button>
        <button class="confirm" :disabled="!hasChoice" @tap="emit('confirm', choice)">确定</button>
      </view>
    </view>
  </view>
</template>

<style scoped>
.mask { position: fixed; z-index: 8; inset: 0; display: flex; align-items: flex-end; background: rgba(0,0,0,.4); }
.backdrop { position: absolute; inset: 0; }
.sheet { position: relative; width: 100%; padding: 30rpx 30rpx calc(24rpx + env(safe-area-inset-bottom)); box-sizing: border-box; border-radius: 24rpx 24rpx 0 0; color: #111; background: white; animation: slide-up .22s ease-out; }
.sheet-title { text-align: center; font-size: 32rpx; font-weight: 600; padding-bottom: 22rpx; }
.status { padding: 20rpx 6rpx; text-align: center; color: #777; font-size: 25rpx; }
.list { max-height: 45vh; }
.patient { display: flex; align-items: center; gap: 12rpx; padding: 0 6rpx; border-top: 1rpx solid #eee; }
.select-patient { display: flex; flex: 1; min-width: 0; align-items: center; justify-content: space-between; gap: 12rpx; padding: 20rpx 0; }
.patient-info { min-width: 0; overflow-wrap: anywhere; }
.meta { color: #777; font-size: 24rpx; }
.radio { flex-shrink: 0; width: 34rpx; height: 34rpx; line-height: 34rpx; border: 2rpx solid #ccc; border-radius: 50%; text-align: center; }
.radio.active { color: white; background: #5ba7e5; border-color: #5ba7e5; }
.edit { flex: 0 0 auto; margin: 0; padding: 0 16rpx; line-height: 64rpx; font-size: 25rpx; color: #458dc4; background: white; }
.add { margin: 8rpx 0 18rpx; font-size: 27rpx; color: #458dc4; background: white; }
.edit::after, .add::after, .confirm::after { border: 0; }
.actions { display: flex; gap: 16rpx; }
.actions button { margin: 0; font-size: 28rpx; line-height: 76rpx; }
.cancel { flex: 1; background: white; }
.confirm { flex: 2; background: #5ba7e5; color: white; }
.confirm[disabled] { background: #d8d8d8; color: white; }
@keyframes slide-up { from { transform: translateY(100%); } to { transform: translateY(0); } }
</style>
